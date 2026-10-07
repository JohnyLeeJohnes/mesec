# Datová vrstva Měšce: šifrování souboru PINem a počítání nad rozpočtem. O okně nic neví,
# takže ji tests/test.ps1 zkouší i bez něj.
Add-Type -AssemblyName System.Security   # DPAPI

$cs = [Globalization.CultureInfo]::GetCultureInfo('cs-CZ')
$invariant = [Globalization.CultureInfo]::InvariantCulture

$incomeCategory = 'Příjem'
$categories = 'Bydlení', 'Energie', 'Jídlo', 'Doprava', 'Zdravotní pojištění', 'Sociální pojištění', 'Daně',
    'Penzijní spoření', 'Investice', 'Spoření', 'Pojištění', 'Splátky', 'Předplatné', 'Zábava', 'Ostatní', $incomeCategory

# ---- Šifrování ----
# Trezor: 'MESEC1' | kola PBKDF2 (int32) | sůl (16) | IV (16) | AES-256-CBC | HMAC-SHA256 všeho předchozího (32).
# Čtyřmístný PIN má jen 10 000 možností a sám by šel uhodnout hrubou silou za pár sekund. Soubor na disku je
# proto ještě zabalený do DPAPI, které ho váže na účet Windows. Bez DPAPI je jen záloha, aby šla otevřít jinde.
$magic = 'MESEC1'
$headerLength = 42
$kdfRounds = 200000

function Join-Bytes {
    $stream = [IO.MemoryStream]::new()
    foreach ($part in $args) { $stream.Write($part, 0, $part.Length) }
    , $stream.ToArray()
}

function Test-Vault([byte[]]$bytes) {
    $bytes.Length -ge $headerLength + 48 -and [Text.Encoding]::ASCII.GetString($bytes, 0, $magic.Length) -ceq $magic
}

# Z PINu udělá klíč pro šifrování a druhý pro kontrolní součet. Bez soli vznikne nová (nový PIN).
function New-Key([string]$pin, [byte[]]$salt, [int]$rounds = $kdfRounds) {
    if (-not $salt) {
        $salt = New-Object byte[] 16
        [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($salt)
    }
    $kdf = [Security.Cryptography.Rfc2898DeriveBytes]::new($pin, $salt, $rounds, [Security.Cryptography.HashAlgorithmName]::SHA256)
    $hmac = [Security.Cryptography.HMACSHA256]::new($kdf.GetBytes(32))
    $kdf.Dispose()
    @{
        Salt = $salt; Rounds = $rounds
        Enc = $hmac.ComputeHash([Text.Encoding]::ASCII.GetBytes('enc'))
        Mac = $hmac.ComputeHash([Text.Encoding]::ASCII.GetBytes('mac'))
    }
}

# Rozpočet zašifrovaný jen PINem. Takhle vypadá záloha; Save-Mesec kolem toho přidává DPAPI.
function Protect-Mesec($key, $data) {
    $aes = [Security.Cryptography.Aes]::Create()   # AES-256-CBC s novým náhodným IV
    $aes.Key = $key.Enc
    $plain = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -Compress -Depth 4 -InputObject $data))
    $cipher = $aes.CreateEncryptor().TransformFinalBlock($plain, 0, $plain.Length)
    $body = Join-Bytes ([Text.Encoding]::ASCII.GetBytes($magic)) ([BitConverter]::GetBytes([int]$key.Rounds)) $key.Salt $aes.IV $cipher
    $aes.Dispose()
    Join-Bytes $body ([Security.Cryptography.HMACSHA256]::new($key.Mac).ComputeHash($body))
}

# Vrací @{ Key; Data }, při špatném PINu $null. PIN se nikde neukládá: pozná se podle toho, že sedí HMAC.
function Unprotect-Mesec([byte[]]$vault, [string]$pin) {
    $rounds = if (Test-Vault $vault) { [BitConverter]::ToInt32($vault, $magic.Length) } else { 0 }
    # Horní mez: podvržený soubor nesmí okno zaseknout na hodiny odvozováním klíče.
    if ($rounds -lt 1 -or $rounds -gt 5000000) { throw 'Soubor s daty je poškozený.' }

    $key = New-Key $pin ([byte[]]$vault[10..25]) $rounds
    $bodyLength = $vault.Length - 32
    $expected = [Security.Cryptography.HMACSHA256]::new($key.Mac).ComputeHash($vault, 0, $bodyLength)
    # Porovnává se vždy všech 32 bajtů, ať čas nic neprozradí.
    $difference = 0
    for ($i = 0; $i -lt 32; $i++) { $difference = $difference -bor ($expected[$i] -bxor $vault[$bodyLength + $i]) }
    if ($difference) { return $null }

    $aes = [Security.Cryptography.Aes]::Create()
    $aes.Key = $key.Enc
    $aes.IV = [byte[]]$vault[26..41]
    $plain = $aes.CreateDecryptor().TransformFinalBlock($vault, $headerLength, $bodyLength - $headerLength)
    $aes.Dispose()
    @{ Key = $key; Data = ConvertFrom-MesecJson ([Text.Encoding]::UTF8.GetString($plain)) }
}

function Save-Mesec([string]$path, $key, $data) {
    $null = New-Item -ItemType Directory -Force (Split-Path $path)
    $bytes = [Security.Cryptography.ProtectedData]::Protect((Protect-Mesec $key $data), $null, 'CurrentUser')
    # Nejdřív vedle a pak vyměnit: pád uprostřed zápisu nesmí o data připravit.
    [IO.File]::WriteAllBytes("$path.new", $bytes)
    if (Test-Path -LiteralPath $path) { [IO.File]::Replace("$path.new", $path, [NullString]::Value) }
    else { [IO.File]::Move("$path.new", $path) }
}

# Vrací @{ Key; Data; Backup }, při špatném PINu $null. Backup = soubor byl záloha bez DPAPI.
function Open-Mesec([string]$path, [string]$pin) {
    $bytes = [IO.File]::ReadAllBytes($path)
    $backup = Test-Vault $bytes
    if (-not $backup) {
        try { $bytes = [Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, 'CurrentUser') }
        catch { throw 'Data patří jinému účtu Windows, nebo jsou poškozená. Pomůže jen obnova ze zálohy.' }
    }
    $opened = Unprotect-Mesec $bytes $pin
    if ($opened) { $opened.Backup = $backup }
    $opened
}

# ---- Rozpočet ----
# items: @{ id; name; amount; day; to; cat; from; until }. Měsíce jsou texty 'yyyy-MM', takže jdou porovnávat.
# Položka je pravidelná platba: platí každý měsíc od from do until včetně, prázdné until = bez omezení.
# Změna založí od daného měsíce novou verzi se stejným id, takže starší měsíce zůstanou.
# skipped: 'yyyy-MM|id' za každý měsíc, ve kterém je platba smazaná jen pro ten měsíc.

function New-Mesec { @{ items = @(); skipped = @() } }

# Co přijde ze souboru, srovná do známých typů; cokoli navíc zahodí (třeba zaškrtnutí "zaplaceno" ze starších verzí).
function ConvertFrom-MesecJson([string]$json) {
    $raw = ConvertFrom-Json $json
    @{
        items = @(foreach ($item in $raw.items) {
            @{
                id = "$($item.id)"; name = "$($item.name)"; to = "$($item.to)"; cat = "$($item.cat)"
                amount = [decimal]$item.amount; day = [int]$item.day
                from = "$($item.from)"; until = "$($item.until)"
            }
        })
        skipped = @(foreach ($mark in $raw.skipped) { "$mark" })
    }
}

function Get-MonthKey([DateTime]$date) { $date.ToString('yyyy-MM') }
function Get-MonthStart([string]$month) { [DateTime]::ParseExact($month, 'yyyy-MM', $invariant) }
function Add-Month([string]$month, [int]$count) { Get-MonthKey (Get-MonthStart $month).AddMonths($count) }

# "Říjen 2026"
function Format-Month([string]$month) {
    $text = (Get-MonthStart $month).ToString('MMMM yyyy', $cs)
    $text.Substring(0, 1).ToUpper($cs) + $text.Substring(1)
}

# "do října 2026"
function Format-Until([string]$month) {
    $start = Get-MonthStart $month
    "do $($cs.DateTimeFormat.MonthGenitiveNames[$start.Month - 1]) $($start.Year)"
}

# "15 000 Kč", haléře jen když nějaké jsou
function Format-Money([decimal]$amount) {
    $amount.ToString($(if ($amount % 1) { 'N2' } else { 'N0' }), $cs) + ' Kč'
}

# Částka z formuláře: "1500", "1 500", "1499,90". Cokoli jiného (i "1.500", které může znamenat obojí) je $null.
function ConvertTo-Amount([string]$text) {
    $clean = $text -replace '[\s ]|Kč'
    if ($clean -notmatch '^\d{1,9}([.,]\d{1,2})?$') { return }
    $amount = [decimal]::Parse(($clean -replace ',', '.'), $invariant)
    if ($amount -gt 0) { $amount }
}

# ponytail: vynechané měsíce se hledají v prostém seznamu. Po letech používání z něj udělej HashSet.
function Get-MonthItems($data, [string]$month) {
    @($data.items | Where-Object {
            $_.from -le $month -and (-not $_.until -or $_.until -ge $month) -and $data.skipped -notcontains "$month|$($_.id)"
        } | Sort-Object { $_.day }, { $_.name })
}

# Poslední měsíc platby přes všechny její verze; '' = bez omezení.
function Get-EntryEnd($data, [string]$id) {
    @($data.items | Where-Object { $_.id -eq $id } | Sort-Object { $_.from })[-1].until
}

function Get-Total($items) {
    $total = [decimal]0
    foreach ($item in $items) { $total += $item.amount }
    $total
}

function Get-Summary($data, [string]$month) {
    $items = Get-MonthItems $data $month
    @{
        Income = Get-Total @($items | Where-Object { $_.cat -eq $incomeCategory })
        Expenses = Get-Total @($items | Where-Object { $_.cat -ne $incomeCategory })
    }
}

# Výdaje měsíce po typech, od největšího.
function Get-Breakdown($data, [string]$month) {
    Get-MonthItems $data $month | Where-Object { $_.cat -ne $incomeCategory } | Group-Object { $_.cat } |
        ForEach-Object { @{ Name = $_.Name; Amount = Get-Total $_.Group } } | Sort-Object { $_.Amount } -Descending
}

# Dvanáct měsíců roku; budoucí měsíce počítají s platbami, které do nich dosáhnou.
function Get-Year($data, [int]$year) {
    foreach ($number in 1..12) {
        $month = '{0}-{1:00}' -f $year, $number
        $summary = Get-Summary $data $month
        $summary.Month = $month
        $summary
    }
}

# Uloží platbu z formuláře: $entry = @{ id (prázdné = nová); name; amount; day; to; cat; until ('' = bez omezení) }.
# Od měsíce $month dál platí to, co je ve formuláři; starší měsíce zůstanou, jak byly.
function Set-Entry($data, [string]$month, $entry) {
    $id = if ($entry.id) { $entry.id } else { [guid]::NewGuid().ToString('N').Substring(0, 8) }
    Remove-Entry $data $month $id
    $data.items += @{
        id = $id; name = $entry.name; amount = [decimal]$entry.amount; day = [int]$entry.day
        to = "$($entry.to)"; cat = $entry.cat; from = $month; until = "$($entry.until)"
    }
}

# Smaže platbu od měsíce $month dál; starší měsíce zůstanou, jak byly.
function Remove-Entry($data, [string]$month, [string]$id) {
    $data.items = @($data.items | Where-Object { $_.id -ne $id -or $_.from -lt $month })
    foreach ($item in $data.items) {
        if ($item.id -eq $id -and (-not $item.until -or $item.until -ge $month)) { $item.until = Add-Month $month -1 }
    }
}

# Smaže platbu jen pro měsíc $month; před ním i po něm běží dál.
function Skip-Entry($data, [string]$month, [string]$id) { $data.skipped += "$month|$id" }

# ---- Ukázka ----
# Vymyšlený rozpočet živnostníka za poslední rok, počítaný od dneška, aby nezestárl.
function New-DemoMesec {
    $now = Get-MonthKey ([DateTime]::Today)
    $data = New-Mesec
    # název, částka, den, příjemce, typ, začátek a konec (před kolika měsíci; záporné = v budoucnu, '' = bez omezení)
    $rows = @(
        @('Faktury', 74000, 10, 'Klienti', $incomeCategory, 14, 6),
        @('Faktury', 81000, 10, 'Klienti', $incomeCategory, 5, ''),
        @('Nájem', 16500, 5, 'Pronajímatel', 'Bydlení', 14, 4),
        @('Nájem', 17800, 5, 'Pronajímatel', 'Bydlení', 3, ''),
        @('Elektřina a plyn', 2950, 15, 'Dodavatel energií', 'Energie', 14, ''),
        @('Jídlo', 9500, 1, 'Nákupy a obědy', 'Jídlo', 14, ''),
        @('Kupón na MHD', 550, 1, 'Dopravní podnik', 'Doprava', 14, ''),
        @('Zdravotní pojištění', 3300, 8, 'Zdravotní pojišťovna', 'Zdravotní pojištění', 14, ''),
        @('Sociální pojištění', 5000, 8, 'Správa sociálního zabezpečení', 'Sociální pojištění', 14, ''),
        @('Záloha na daň', 4200, 15, 'Finanční úřad', 'Daně', 14, ''),
        @('Penzijko', 1700, 12, 'Penzijní společnost', 'Penzijní spoření', 14, ''),
        @('Akciové fondy', 6000, 12, 'Broker', 'Investice', 9, ''),
        @('Rezerva', 4000, 11, 'Spořicí účet', 'Spoření', 14, ''),
        @('Životní pojištění', 950, 25, 'Pojišťovna', 'Pojištění', 14, ''),
        @('Splátka auta', 5400, 18, 'Leasingová společnost', 'Splátky', 14, -9),
        @('Internet a mobil', 899, 20, 'Operátor', 'Předplatné', 14, ''),
        @('Filmy a hudba', 429, 3, '', 'Předplatné', 14, ''),
        @('Splátka pračky', 1990, 14, 'Elektro', 'Splátky', 7, 2),
        @('Jazykový kurz', 2400, 9, 'Jazyková škola', 'Zábava', 4, 0),
        @('Posilovna', 990, 22, 'Fitness centrum', 'Zábava', 10, '')
    )
    $number = 0
    $data.items = @(foreach ($row in $rows) {
        @{
            id = "demo$(($number++))"; name = $row[0]; amount = [decimal]$row[1]; day = $row[2]; to = $row[3]; cat = $row[4]
            from = Add-Month $now (-$row[5]); until = if ($row[6] -is [string]) { '' } else { Add-Month $now (-$row[6]) }
        }
    })
    # Dva měsíce se kupón na MHD nekupoval.
    $transit = ($data.items | Where-Object { $_.name -eq 'Kupón na MHD' }).id
    $data.skipped = @("$(Add-Month $now -3)|$transit", "$(Add-Month $now -2)|$transit")
    $data
}
