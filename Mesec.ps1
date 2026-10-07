# Měšec: pravidelné měsíční platby pod PINem. Okno je popsané v Mesec.xaml, šifrování a počítání v Data.ps1.
#   Mesec.ps1                       spustí aplikaci
#   Mesec.ps1 -Install              vytvoří zástupce s ikonou v nabídce Start, na ploše a ve složce s Měšcem
#   Mesec.ps1 -Demo                 ukázková data bez PINu; na disk se nic neukládá
#   Mesec.ps1 -DataPath x.bin       datový soubor jinde než v %APPDATA% (testy)
#   Mesec.ps1 -Screenshot obr.png   uloží obrázek okna a skončí (obrázky do README)
param([switch]$Install, [switch]$Demo, [string]$DataPath, [string]$Screenshot)

$ErrorActionPreference = 'Stop'
$icon = Join-Path $PSScriptRoot 'assets\mesec.ico'

if ($Install) {
    # Soubory rozbalené ze ZIPu staženého prohlížečem nesou značku "z internetu" a Windows se u nich
    # může ptát nebo je odmítnout. Po instalaci už značku nemají. (Kde to nejde, zůstane vše při starém.)
    Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

    $shell = New-Object -ComObject WScript.Shell
    foreach ($directory in [Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('DesktopDirectory'), $PSScriptRoot) {
        # WScript.Shell ukládá texty v kódové stránce systému a "ě" v ní být nemusí.
        # Proto se zástupce uloží jako Mesec.lnk a přejmenuje až potom, a popisek se háčkům vyhýbá.
        $plain = Join-Path $directory 'Mesec.lnk'
        $link = $shell.CreateShortcut($plain)
        # conhost --headless spustí PowerShell bez okna konzole.
        $link.TargetPath = "$env:SystemRoot\System32\conhost.exe"
        $link.Arguments = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        $link.WorkingDirectory = $PSScriptRoot
        $link.IconLocation = $icon
        $link.Description = 'Výdaje a platby pod PINem'
        $link.Save()
        if ($shell.CreateShortcut($plain).Arguments -ne $link.Arguments) {
            Remove-Item $plain
            throw "Cesta $PSScriptRoot obsahuje znaky, které zástupce neunese. Přesuň složku jinam a zkus to znovu."
        }
        Move-Item $plain (Join-Path $directory 'Měšec.lnk') -Force
    }
    'Hotovo. Zástupce Měšec je v nabídce Start, na ploše a v téhle složce.'
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, Microsoft.VisualBasic
. (Join-Path $PSScriptRoot 'Data.ps1')

# Dvě volání Windows API. Typ se skládá za běhu, ne přes Add-Type s kódem v C#: ten by kvůli nim pouštěl
# kompilátor a start by se o znatelný kus protáhl. Když se to nepovede (třeba kvůli zásadám počítače), Měšec
# běží dál, jen má světlý titulek a na hlavním panelu ikonu PowerShellu.
$native = $null
try {
    $assembly = [AppDomain]::CurrentDomain.DefineDynamicAssembly((New-Object Reflection.AssemblyName 'MesecNative'), 'Run')
    $type = $assembly.DefineDynamicModule('MesecNative').DefineType('Mesec.Native', 'Public, Class')
    # Knihovna, funkce, parametry; obě vracejí HRESULT.
    $imports = @('dwmapi.dll', 'DwmSetWindowAttribute', @([IntPtr], [int], [int].MakeByRefType(), [int])),
        @('shell32.dll', 'SetCurrentProcessExplicitAppUserModelID', @([string]))
    foreach ($import in $imports) {
        $method = $type.DefinePInvokeMethod($import[1], $import[0], 'Public, Static, PinvokeImpl', 'Standard', [int], [Type[]]$import[2], 'Winapi', 'Unicode')
        $method.SetImplementationFlags('PreserveSig')
    }
    $native = $type.CreateType()
    # Okno hostí powershell.exe, takže by ho Windows na hlavním panelu přiřadily k PowerShellu a ukázaly jeho
    # ikonu. S vlastním označením je Měšec na panelu sám za sebe a s ikonou svého okna.
    $null = $native::SetCurrentProcessExplicitAppUserModelID('JohnyLeeJohnes.Mesec')
} catch { }

function Resolve-Target([string]$path) { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($path) }

# Data jsou mimo složku s aplikací, takže se do repozitáře nedostanou ani omylem.
$dataFile = if ($DataPath) { Resolve-Target $DataPath } else { Join-Path $env:APPDATA 'Mesec\data.bin' }

# Key a Data je odemčený trezor; po zamknutí je obojí $null. Mode: 'Unlock' = zadání PINu,
# 'Setup' = volba nového (FirstPin je první zadání, které čeká na potvrzení).
$state = @{
    Month = Get-MonthKey ([DateTime]::Today)
    Key = $null; Data = $null
    Mode = 'Unlock'; Pin = ''; FirstPin = $null; LockError = $null
    EditId = $null; EditHint = $null; EditError = $null; Deleting = $false
    EditDay = 1      # den v měsíci ve formuláři
    EditUntil = ''   # konec platby ve formuláři: 'yyyy-MM', '' = bez omezení
    Pick = $null     # otevřené vybírátko měsíce, viz Open-Picker
}

# ---- Zámek ----

function Update-Lock {
    $ui.LockPrompt.Text =
        if ($state.Mode -eq 'Unlock') { 'Zadej PIN' }
        elseif ($state.FirstPin) { 'Zadej ho ještě jednou' }
        elseif ($state.Data) { 'Zvol si nový PIN' }
        else { 'Zvol si čtyřmístný PIN' }

    for ($i = 0; $i -lt 4; $i++) {
        $filled = $i -lt $state.Pin.Length
        $ui.Dots.Children[$i].Fill = if ($filled) { $window.FindResource('Accent') } else { [Windows.Media.Brushes]::Transparent }
        $ui.Dots.Children[$i].Stroke = $window.FindResource($(if ($filled) { 'Accent' } else { 'Muted' }))
    }

    $ui.LockStatus.Foreground = $window.FindResource($(if ($state.LockError) { 'Danger' } else { 'Muted' }))
    $ui.LockStatus.Text =
        if ($state.LockError) { $state.LockError }
        elseif ($state.Mode -eq 'Unlock') { '' }
        elseif ($state.Data) { 'Esc tě vrátí zpět.' }
        else { 'PINem se zašifrují tvoje data. Zapomenutý PIN nejde obnovit.' }
    $ui.RestoreButton.Visibility = if ($state.Mode -eq 'Setup' -and -not $state.Data) { 'Visible' } else { 'Collapsed' }
}

function Show-Lock([string]$mode) {
    $state.Mode = $mode
    $state.Pin = ''; $state.FirstPin = $null; $state.LockError = $null
    if ($mode -eq 'Unlock') {
        # Zamčeno: klíč, data ani vykreslené částky v paměti nezůstávají.
        $state.Key = $null; $state.Data = $null
        Update-View
    }
    $ui.EditorView.Visibility = 'Collapsed'
    $ui.MainView.Visibility = 'Collapsed'
    $ui.LockView.Visibility = 'Visible'
    $null = $ui.LockView.Focus()
    Update-Lock
}

function Show-Main {
    $state.Pin = ''; $state.FirstPin = $null
    $ui.LockView.Visibility = 'Collapsed'
    $ui.MainView.Visibility = 'Visible'
    Update-View
}

function Show-LockError([string]$text) {
    $state.LockError = $text
    $window.FindResource('Shake').Begin($ui.Dots)
}

function Add-Digit([string]$digit) {
    $state.Pin += $digit
    $state.LockError = $null
    Update-Lock
    if ($state.Pin.Length -lt 4) { return }

    # Čtvrtá číslice odesílá sama. Tečka se vykreslí dřív, než se okno na chvilku zastaví u odvozování klíče.
    $window.Dispatcher.Invoke([Action]{ }, [Windows.Threading.DispatcherPriority]::Render)
    $pin = $state.Pin
    $state.Pin = ''
    Enter-Pin $pin
    Update-Lock
}

function Enter-Pin([string]$pin) {
    try {
        if ($state.Mode -eq 'Unlock') {
            $opened = Open-Mesec $dataFile $pin
            if (-not $opened) { Show-LockError 'Špatný PIN.'; return }
            $state.Key = $opened.Key
            $state.Data = $opened.Data
            # Obnovená záloha je chráněná jen PINem; uložením se sváže s tímhle účtem Windows.
            if ($opened.Backup) { Save-State }
        }
        elseif (-not $state.FirstPin) { $state.FirstPin = $pin; return }
        elseif ($pin -ne $state.FirstPin) {
            $state.FirstPin = $null
            Show-LockError 'PINy se liší. Zkus to znovu od začátku.'
            return
        }
        else {
            $state.Key = New-Key $pin
            if (-not $state.Data) { $state.Data = New-Mesec }
            Save-State
        }
        Show-Main
    }
    catch { Show-LockError "$_" }
}

function Save-State {
    if ($Demo) { return }   # ukázka na disk nesahá
    try { Save-Mesec $dataFile $state.Key $state.Data }
    catch { $null = [Windows.MessageBox]::Show("Uložení se nepovedlo: $_", 'Měšec', 'OK', 'Error') }
}

# ---- Přehled ----

# Podíl jako dvojice šířek sloupců (nebo výšek řádků) mřížky.
function Get-Stars([decimal]$part, [decimal]$whole) {
    $fill = if ($whole -gt 0) { [int][Math]::Round(1000 * [Math]::Min($part, $whole) / $whole) } else { 0 }
    "$fill*", "$(1000 - $fill)*"
}

function Update-View {
    $data = if ($state.Data) { $state.Data } else { New-Mesec }
    $month = $state.Month
    $summary = Get-Summary $data $month
    $left = $summary.Income - $summary.Expenses

    $ui.MonthText.Text = Format-Month $month
    $ui.IncomeText.Text = Format-Money $summary.Income
    $ui.ExpensesText.Text = Format-Money $summary.Expenses
    $ui.LeftLabel.Text = if ($left -lt 0) { 'Chybí' } else { 'Zbývá' }
    $ui.LeftText.Text = Format-Money ([Math]::Abs($left))
    $ui.LeftText.Foreground = $window.FindResource($(if ($left -lt 0) { 'Danger' } else { 'Text' }))

    $rows = @(foreach ($item in Get-MonthItems $data $month) {
        $end = Get-EntryEnd $data $item.id
        $notes = $item.to, $(if ($end -eq $month) { 'naposledy' } elseif ($end) { Format-Until $end })
        [pscustomobject]@{
            Id = $item.id
            Day = "$($item.day)."
            Name = $item.name
            Note = ($notes | Where-Object { $_ }) -join ' · '
            Category = $item.cat
            Amount = $(if ($item.cat -eq $incomeCategory) { '+' }) + (Format-Money $item.amount)
        }
    })
    $ui.Rows.ItemsSource = $rows
    $ui.EmptyText.Visibility = if ($rows) { 'Collapsed' } else { 'Visible' }

    # Pruhy jsou vůči největšímu typu, procenta vůči všem výdajům.
    $parts = @(Get-Breakdown $data $month)
    $ui.Breakdown.ItemsSource = @(foreach ($part in $parts) {
        $stars = Get-Stars $part.Amount $parts[0].Amount
        $share = [Math]::Round(100 * $part.Amount / $summary.Expenses)
        [pscustomobject]@{
            Name = $part.Name
            Amount = Format-Money $part.Amount
            Share = if ($share -lt 1) { '<1 %' } else { "$share %" }
            Fill = $stars[0]; Rest = $stars[1]
        }
    })
    $ui.BreakdownEmpty.Visibility = if ($parts) { 'Collapsed' } else { 'Visible' }

    $year = [int]$month.Substring(0, 4)
    $months = @(Get-Year $data $year)
    $top = [decimal]0
    $sum = [decimal]0
    foreach ($entry in $months) {
        $top = [Math]::Max($top, $entry.Expenses)
        $sum += $entry.Expenses
    }
    # Průměr jen z měsíců, kdy se něco platilo, ať ho prázdný začátek roku nestahuje dolů.
    $spent = @($months | Where-Object { $_.Expenses -gt 0 }).Count
    $average = if ($spent) { $sum / $spent } else { 0 }
    $bars = @(foreach ($entry in $months) {
        $stars = Get-Stars $entry.Expenses $top
        [pscustomobject]@{
            Month = $entry.Month
            Label = (Get-MonthStart $entry.Month).ToString('MMM', $cs)
            Tip = "$(Format-Month $entry.Month)`nvýdaje $(Format-Money $entry.Expenses)`npříjmy $(Format-Money $entry.Income)"
            Fill = $stars[0]; Rest = $stars[1]
            Current = $entry.Month -eq $month
        }
    })
    $ui.Bars.ItemsSource = $bars
    $ui.BarLabels.ItemsSource = $bars
    $ui.YearTitle.Text = "Výdaje v roce $year"
    $ui.AverageText.Text = if ($spent) { "průměr $(Format-Money ([Math]::Round($average)))" } else { '' }
    $ui.AverageMark.Visibility = if ($spent) { 'Visible' } else { 'Hidden' }
    $stars = Get-Stars $average $top
    $ui.AverageFill.Height = $stars[0]
    $ui.AverageRest.Height = $stars[1]
}

function Set-Month([string]$month) {
    $state.Month = $month
    Update-View
}

# ---- Vybírátko měsíce ----

# Měsíc a rok se nikde nepíšou, vždycky se volí tady. $for říká, co se vybírá: 'Month' = zobrazený měsíc
# v záhlaví, 'Until' = konec platby ve formuláři. Ten nesmí být před zobrazeným měsícem a jde i zrušit.
function Open-Picker([string]$for) {
    $until = $for -eq 'Until'
    $value = if ($until) { $state.EditUntil } else { $state.Month }
    $state.Pick = @{
        For = $for; Value = $value
        Min = if ($until) { $state.Month } else { '' }
        Year = [int]$(if ($value) { $value } else { $state.Month }).Substring(0, 4)
    }
    $ui.PickerClearButton.Visibility = if ($until) { 'Visible' } else { 'Collapsed' }
    $ui.MonthPicker.PlacementTarget = if ($until) { $ui.UntilButton } else { $ui.MonthButton }
    Update-Picker
    $ui.MonthPicker.IsOpen = $true
}

function Update-Picker {
    $pick = $state.Pick
    $ui.PickerYear.Text = $pick.Year
    # Měsíce jsou v datech 'yyyy-MM', takže rok má vždycky čtyři číslice.
    $ui.PickerPrevYear.IsEnabled = $pick.Year -gt $(if ($pick.Min) { [int]$pick.Min.Substring(0, 4) } else { 1000 })
    $ui.PickerNextYear.IsEnabled = $pick.Year -lt 9999
    foreach ($chip in $ui.PickerMonths.Children) {
        $month = Get-MonthKey ([DateTime]::new($pick.Year, $chip.Tag, 1))
        $chip.IsChecked = $month -eq $pick.Value
        $chip.IsEnabled = $month -ge $pick.Min
    }
}

# $month = zvolený měsíc, '' = bez omezení
function Close-Picker([string]$month) {
    $ui.MonthPicker.IsOpen = $false
    if ($state.Pick.For -eq 'Until') {
        $state.EditUntil = $month
        Update-Editor
    }
    else { Set-Month $month }
}

# ---- Formulář platby ----

# "říjen 2026": zobrazený měsíc do věty
function Format-Shown { (Format-Month $state.Month).ToLower($cs) }

function Update-Editor {
    $ui.DayButton.Content = "$($state.EditDay)."
    $ui.UntilButton.Content = if ($state.EditUntil) { Format-Month $state.EditUntil } else { 'Bez omezení' }
    # Smazat se nejdřív zeptá, jestli jen zobrazený měsíc, nebo i všechny další.
    $ui.DeleteButton.Visibility = if ($state.EditId -and -not $state.Deleting) { 'Visible' } else { 'Collapsed' }
    $ui.DeleteChoices.Visibility = if ($state.Deleting) { 'Visible' } else { 'Collapsed' }
    $ui.EditorStatus.Foreground = $window.FindResource($(if ($state.EditError) { 'Danger' } else { 'Muted' }))
    $ui.EditorStatus.Text =
        if ($state.EditError) { $state.EditError }
        elseif ($state.Deleting) { "Smazat jen v měsíci $(Format-Shown), nebo i ve všech dalších? Starší měsíce zůstanou, jak byly." }
        else { $state.EditHint }
}

# $row = řádek rozpisu, $null = nová platba
function Open-Editor($row) {
    $item = if ($row) { Get-MonthItems $state.Data $state.Month | Where-Object { $_.id -eq $row.Id } }
    $state.EditId = if ($item) { $item.id } else { $null }
    $state.EditError = $null
    $state.Deleting = $false
    $state.EditHint =
        if (-not $item) { "První platba bude v měsíci $(Format-Shown)." }
        elseif ($item.from -lt $state.Month) { "Změna platí od měsíce $(Format-Shown) dál. Starší měsíce zůstanou, jak byly." }

    $ui.EditorTitle.Text = if ($item) { 'Upravit platbu' } else { 'Nová pravidelná platba' }
    $ui.NameBox.Text = if ($item) { $item.name } else { '' }
    $ui.AmountBox.Text = if ($item) { $item.amount.ToString($(if ($item.amount % 1) { '0.00' } else { '0' }), $cs) } else { '' }
    $state.EditDay = if ($item) { $item.day } else { [DateTime]::Today.Day }
    $ui.ToBox.Text = if ($item) { $item.to } else { '' }
    $category = if ($item) { $item.cat } else { 'Ostatní' }
    foreach ($chip in $ui.Categories.Children) { $chip.IsChecked = $chip.Content -eq $category }
    $state.EditUntil = if ($item) { "$(Get-EntryEnd $state.Data $item.id)" } else { '' }
    Update-Editor

    $ui.EditorView.Visibility = 'Visible'
    $null = $ui.NameBox.Focus()
    $ui.NameBox.SelectAll()
}

function Close-Editor { $ui.EditorView.Visibility = 'Collapsed' }

function Save-Editor {
    $name = $ui.NameBox.Text.Trim()
    $amount = ConvertTo-Amount $ui.AmountBox.Text
    $state.Deleting = $false
    $state.EditError =
        if (-not $name) { 'Doplň název.' }
        elseif (-not $amount) { 'Částku napiš jako číslo větší než nula, třeba 1500 nebo 1499,90.' }
    if ($state.EditError) { Update-Editor; return }

    Set-Entry $state.Data $state.Month @{
        id = $state.EditId; name = $name; amount = $amount; day = $state.EditDay; to = $ui.ToBox.Text.Trim()
        cat = ($ui.Categories.Children | Where-Object { $_.IsChecked }).Content
        until = $state.EditUntil
    }
    Save-State
    Close-Editor
    Update-View
}

# $onward = od zobrazeného měsíce dál, jinak jen zobrazený měsíc
function Remove-Edited([bool]$onward) {
    if ($onward) { Remove-Entry $state.Data $state.Month $state.EditId }
    else { Skip-Entry $state.Data $state.Month $state.EditId }
    Save-State
    Close-Editor
    Update-View
}

# ---- Obrázek okna ----

function Save-Screenshot([string]$path) {
    $root = $window.Content
    $scale = [Windows.Media.VisualTreeHelper]::GetDpi($root).DpiScaleX
    $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new(
        [int][Math]::Ceiling($root.ActualWidth * $scale), [int][Math]::Ceiling($root.ActualHeight * $scale),
        96 * $scale, 96 * $scale, [Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($root)

    $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [IO.File]::Create($path)
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
}

# ---- Okno ----

try {
    $window = [Windows.Markup.XamlReader]::Load([Xml.XmlReader]::Create((Join-Path $PSScriptRoot 'Mesec.xaml')))
    if (Test-Path -LiteralPath $icon) { $window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$icon) }

    $ui = @{}
    'MainView', 'PrevButton', 'MonthButton', 'MonthText', 'NextButton', 'TodayButton', 'VaultButtons', 'BackupButton',
    'PinButton', 'LockButton', 'IncomeText', 'ExpensesText', 'LeftLabel', 'LeftText', 'AddButton', 'Rows', 'EmptyText',
    'Breakdown', 'BreakdownEmpty', 'AverageText', 'YearTitle', 'Bars', 'AverageMark', 'AverageRest', 'AverageFill',
    'BarLabels', 'EditorView', 'EditorTitle', 'NameBox', 'AmountBox', 'DayButton', 'ToBox', 'Categories', 'UntilButton',
    'EditorStatus', 'SaveButton', 'CancelButton', 'DeleteButton', 'DeleteChoices', 'DeleteMonthButton',
    'DeleteOnwardButton', 'DayPicker', 'PickerDays', 'MonthPicker', 'PickerPrevYear', 'PickerYear', 'PickerNextYear',
    'PickerMonths', 'PickerClearButton', 'LockView', 'LockPrompt', 'Dots', 'LockStatus', 'RestoreButton',
    'GatewayButton', 'LockGatewayButton' | ForEach-Object { $ui[$_] = $window.FindName($_) }

    # Když Měšec pustila Bránocesta, nechala v $env:BRANOCESTA cestu ke svému skriptu a v $env:BRANOCESTA_PID
    # číslo svého procesu. Tlačítko bránu vrátí a Měšec zavře. Při spuštění vlastním zástupcem proměnné nejsou
    # a tlačítka zůstanou schovaná.
    $gateway = $env:BRANOCESTA
    if ($gateway -and (Split-Path $gateway -Leaf) -eq 'Branocesta.ps1' -and (Test-Path -LiteralPath $gateway)) {
        # Měšec se zavře, až když se okno brány ukáže, a pošle ho dopředu. Kdyby se zavřel hned, Windows by
        # mezitím aktivovaly jiné okno a brána by se otevřela za ním.
        # $handoff.Tag = @{ Since = čas kliknutí; Called = proces brány, která se nechala zavolat, jinak 0 }
        $handoff = [Windows.Threading.DispatcherTimer]::new()
        $handoff.Interval = [TimeSpan]::FromMilliseconds(50)
        $handoff.Add_Tick({
            $shown = $null
            foreach ($process in [Diagnostics.Process]::GetProcessesByName('powershell')) {
                try {
                    # Zavolaná brána běžela už před kliknutím, nově otevřená vznikla až po něm.
                    if ($process.Id -ne $PID -and $process.MainWindowHandle -ne [IntPtr]::Zero -and
                        ($process.Id -eq $handoff.Tag.Called -or $process.StartTime -ge $handoff.Tag.Since)) { $shown = $process.Id }
                }
                catch { }   # Proces mezitím skončil nebo k němu není přístup.
                finally { $process.Dispose() }
            }
            if (-not $shown -and [DateTime]::Now -lt $handoff.Tag.Since.AddSeconds(20)) { return }
            $handoff.Stop()
            # Když se brána neukázala, Měšec zůstane otevřený, ať člověk neskončí bez okna.
            if (-not $shown) { return }
            try { [Microsoft.VisualBasic.Interaction]::AppActivate($shown) } catch { }
            $window.Close()
        })
        foreach ($button in $ui.GatewayButton, $ui.LockGatewayButton) {
            $button.Visibility = 'Visible'
            $button.Add_Click({
                if ($handoff.IsEnabled) { return }
                $handoff.Tag = @{ Since = [DateTime]::Now; Called = 0 }
                # Brána od verze 1.5.0 se za Měšcem nezavírá, jen se schová a čeká na událost Branocesta.<PID>.
                # Stačí ji zavolat a je zpátky hned, protože se nic nestartuje.
                try {
                    $signal = [Threading.EventWaitHandle]::OpenExisting("Branocesta.$env:BRANOCESTA_PID")
                    if ($signal.Set()) { $handoff.Tag.Called = [int]$env:BRANOCESTA_PID }
                    $signal.Dispose()
                } catch { }   # Událost není: brána je starší nebo už neběží.
                if (-not $handoff.Tag.Called) {
                    # conhost --headless spustí PowerShell bez okna konzole, stejně jako zástupce.
                    Start-Process -FilePath "$env:SystemRoot\System32\conhost.exe" -WorkingDirectory (Split-Path $gateway) `
                        -ArgumentList "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$gateway`""
                }
                $handoff.Start()
            })
        }
    }

    foreach ($category in $categories) {
        $chip = [Windows.Controls.RadioButton]::new()
        $chip.Style = $window.FindResource('Chip')
        $chip.GroupName = 'Category'
        $chip.Content = $category
        $null = $ui.Categories.Children.Add($chip)
    }
    # Štítky vybírátek; Tag nese číslo měsíce nebo dne.
    foreach ($number in 1..12) {
        $chip = [Windows.Controls.RadioButton]::new()
        $chip.Style = $window.FindResource('Chip')
        $chip.GroupName = 'PickerMonth'
        $chip.Content = $cs.DateTimeFormat.MonthNames[$number - 1]
        $chip.Tag = $number
        $null = $ui.PickerMonths.Children.Add($chip)
    }
    foreach ($number in 1..31) {
        $chip = [Windows.Controls.RadioButton]::new()
        $chip.Style = $window.FindResource('Chip')
        $chip.GroupName = 'PickerDay'
        $chip.Padding = [Windows.Thickness]::new(0)   # sedm štítků v řadě je úzkých, dvě číslice by okraj uřízl
        $chip.Content = $number
        $chip.Tag = $number
        $null = $ui.PickerDays.Children.Add($chip)
    }

    $window.Add_SourceInitialized({
        if (-not $native) { return }
        $hwnd = [Windows.Interop.WindowInteropHelper]::new($window).Handle
        # 20 = tmavý režim, 35 = barva titulku, 34 = barva rámečku; barva je #0F1513 jako COLORREF (0x00BBGGRR).
        # Starší Windows volání jen odmítnou a titulek zůstane výchozí.
        foreach ($attribute in @(20, 1), @(35, 0x0013150F), @(34, 0x0013150F)) {
            $value = $attribute[1]
            $null = $native::DwmSetWindowAttribute($hwnd, $attribute[0], [ref]$value, 4)
        }
    })

    # Klávesnice: na zámku číslice (horní řada i bez Shiftu, takže to jde i na české klávesnici),
    # ve formuláři Enter a Esc.
    $window.Add_PreviewKeyDown({
        param($source, $e)
        $picker = $ui.DayPicker, $ui.MonthPicker | Where-Object { $_.IsOpen }
        if ($picker) {
            # Esc zavře jen vybírátko; ostatní klávesy patří jeho tlačítkům, ne formuláři pod ním.
            if ($e.Key -eq 'Escape') {
                $picker.IsOpen = $false
                $e.Handled = $true
            }
        }
        elseif ($ui.LockView.IsVisible) {
            if ("$($e.Key)" -match '^(D|NumPad)(\d)$') { Add-Digit $Matches[2] }
            elseif ($e.Key -eq 'Back') {
                if ($state.Pin) { $state.Pin = $state.Pin.Substring(0, $state.Pin.Length - 1) }
                Update-Lock
            }
            elseif ($e.Key -eq 'Escape' -and $state.Data) { Show-Main }   # změna PINu se dá vzdát
            else { return }
            $e.Handled = $true
        }
        elseif ($ui.EditorView.IsVisible) {
            if ($e.Key -eq 'Escape') { Close-Editor }
            # Enter na tlačítku patří tomu tlačítku.
            elseif ($e.Key -eq 'Return' -and $e.OriginalSource -isnot [Windows.Controls.Button]) { Save-Editor }
            else { return }
            $e.Handled = $true
        }
    })

    # ---- Zámek ----

    $ui.LockButton.Add_Click({ Show-Lock 'Unlock' })
    $ui.PinButton.Add_Click({ Show-Lock 'Setup' })

    # Záloha je trezor bez DPAPI: jde otevřít na jiném počítači, ale chrání ji jen PIN.
    $ui.BackupButton.Add_Click({
        $dialog = [Microsoft.Win32.SaveFileDialog]::new()
        $dialog.Filter = 'Záloha Měšce (*.mesec)|*.mesec'
        $dialog.FileName = "mesec-$([DateTime]::Today.ToString('yyyy-MM-dd')).mesec"
        if (-not $dialog.ShowDialog($window)) { return }
        try {
            [IO.File]::WriteAllBytes($dialog.FileName, (Protect-Mesec $state.Key $state.Data))
            $text = "Záloha je uložená. Otevřeš ji stejným PINem jako teď.`n`nChrání ji jen ten PIN, takže ji nenechávej na sdíleném disku ani v cloudu."
            $null = [Windows.MessageBox]::Show($text, 'Měšec', 'OK', 'Information')
        }
        catch { $null = [Windows.MessageBox]::Show("Záloha se nepovedla: $_", 'Měšec', 'OK', 'Error') }
    })

    $ui.RestoreButton.Add_Click({
        $dialog = [Microsoft.Win32.OpenFileDialog]::new()
        $dialog.Filter = 'Záloha Měšce (*.mesec)|*.mesec|Všechny soubory|*.*'
        if (-not $dialog.ShowDialog($window)) { return }
        try {
            if (-not (Test-Vault ([IO.File]::ReadAllBytes($dialog.FileName)))) { throw 'Tenhle soubor není záloha Měšce.' }
            $null = New-Item -ItemType Directory -Force (Split-Path $dataFile)
            Copy-Item -LiteralPath $dialog.FileName -Destination $dataFile
            Show-Lock 'Unlock'
        }
        catch {
            $state.LockError = "$_"
            Update-Lock
        }
    })

    # ---- Přehled ----

    $ui.PrevButton.Add_Click({ Set-Month (Add-Month $state.Month -1) })
    $ui.NextButton.Add_Click({ Set-Month (Add-Month $state.Month 1) })
    $ui.TodayButton.Add_Click({ Set-Month (Get-MonthKey ([DateTime]::Today)) })
    $ui.AddButton.Add_Click({ Open-Editor $null })

    # Kliknutí na řádek rozpisu otevírá úpravu.
    $ui.Rows.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler]{
        param($list, $e)
        Open-Editor $e.OriginalSource.DataContext
    })

    $ui.Bars.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler]{
        param($list, $e)
        Set-Month $e.OriginalSource.DataContext.Month
    })

    # ---- Formulář platby ----

    $ui.SaveButton.Add_Click({ Save-Editor })
    $ui.CancelButton.Add_Click({ Close-Editor })
    $ui.DeleteButton.Add_Click({
        $state.Deleting = $true
        $state.EditError = $null
        Update-Editor
    })
    $ui.DeleteMonthButton.Add_Click({ Remove-Edited $false })
    $ui.DeleteOnwardButton.Add_Click({ Remove-Edited $true })

    # ---- Vybírátka ----

    $ui.DayButton.Add_Click({
        foreach ($chip in $ui.PickerDays.Children) { $chip.IsChecked = $chip.Tag -eq $state.EditDay }
        $ui.DayPicker.IsOpen = $true
    })
    $ui.PickerDays.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler]{
        param($grid, $e)
        $ui.DayPicker.IsOpen = $false
        $state.EditDay = $e.OriginalSource.Tag
        Update-Editor
    })

    $ui.MonthButton.Add_Click({ Open-Picker 'Month' })
    $ui.UntilButton.Add_Click({ Open-Picker 'Until' })
    $ui.PickerPrevYear.Add_Click({ $state.Pick.Year--; Update-Picker })
    $ui.PickerNextYear.Add_Click({ $state.Pick.Year++; Update-Picker })
    $ui.PickerClearButton.Add_Click({ Close-Picker '' })
    $ui.PickerMonths.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler]{
        param($grid, $e)
        Close-Picker (Get-MonthKey ([DateTime]::new($state.Pick.Year, $e.OriginalSource.Tag, 1)))
    })

    # Klávesnice: po otevření má fokus vybraný (jinak první povolený) štítek, takže jdou šipky a mezerník.
    # Po zavření se fokus vrací na tlačítko, pod kterým vybírátko bylo. Tag vybírátka = mřížka jeho štítků.
    $ui.DayPicker.Tag = $ui.PickerDays
    $ui.MonthPicker.Tag = $ui.PickerMonths
    foreach ($picker in $ui.DayPicker, $ui.MonthPicker) {
        $picker.Add_Opened({
            param($popup)
            $chips = @($popup.Tag.Children | Where-Object { $_.IsEnabled })
            $chip = @($chips | Where-Object { $_.IsChecked }) + $chips | Select-Object -First 1
            if ($chip) { $null = $chip.Focus() }
        })
        $picker.Add_Closed({
            param($popup)
            $null = $popup.PlacementTarget.Focus()
        })
    }

    if ($Demo) {
        $window.Title = 'Měšec (ukázka)'
        $ui.VaultButtons.Visibility = 'Collapsed'
        $state.Data = New-DemoMesec
        Show-Main
    }
    elseif (Test-Path -LiteralPath $dataFile) { Show-Lock 'Unlock' }
    else { Show-Lock 'Setup' }

    if ($Screenshot) {
        $window.Add_ContentRendered({
            Save-Screenshot (Resolve-Target $Screenshot)
            $window.Close()
        })
    }
    $null = $window.ShowDialog()
}
catch {
    # Konzole je schovaná, takže chybu jinak nikdo neuvidí.
    $null = [Windows.MessageBox]::Show("$_", 'Měšec', 'OK', 'Error')
}
