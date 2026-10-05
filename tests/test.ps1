# Zkouška Měšce: nejdřív datová vrstva (šifrování, měsíce), pak průchod oknem.
#   powershell -ExecutionPolicy Bypass -File tests/test.ps1
#
# Okno běží přímo v tomhle procesu a data má v dočasné složce; skutečných dat v %APPDATA% se test nedotkne.
# Klávesy dostává jako události WPF: skutečné stisky by skončily v okně, které máš zrovna otevřené.
$root = Split-Path $PSScriptRoot
$temp = Join-Path ([IO.Path]::GetTempPath()) "mesec-test-$PID"
$null = New-Item -ItemType Directory -Force $temp
$script:fail = 0
# Co se vypíše z obsluhy události, se ztratí; řádky se proto sbírají a vypíšou až po zavření okna.
$script:lines = New-Object System.Collections.ArrayList

function Note([string]$line) { $null = $script:lines.Add($line) }
function Check($what, $actual, $expected) {
    if ("$actual" -ceq "$expected") { Note "ok    $what" }
    else { $script:fail++; Note "FAIL  $what = '$actual' (čekáno '$expected')" }
}
function Spaces([string]$text) { $text -replace ' ', ' ' }   # čeština odděluje tisíce pevnou mezerou

. (Join-Path $root 'Budget.ps1')

# ---- Soubory ----

# Bez BOM čte PowerShell 5.1 skript jako ANSI a rozbije češtinu.
foreach ($source in Get-ChildItem $root, "$root\tests", "$root\tools" -Filter *.ps1) {
    $bytes = [IO.File]::ReadAllBytes($source.FullName)
    Check "$($source.Name) je UTF-8 s BOM" ('{0:X2}{1:X2}{2:X2}' -f $bytes[0], $bytes[1], $bytes[2]) 'EFBBBF'
}

# ---- Šifrování ----

$data = New-Budget
Set-Entry $data '2026-01' @{ name = 'Nájem u paní Šťastné'; amount = 15000.5; day = 31; to = 'Pronajímatel'; cat = 'Bydlení'; monthly = $true }
Set-Entry $data '2026-01' @{ name = 'Výplata'; amount = 50000; day = 10; to = ''; cat = $incomeCategory; monthly = $true }
Set-Entry $data '2026-02' @{ name = 'Pračka'; amount = 9990; day = 14; to = ''; cat = 'Bydlení'; monthly = $false }

$key = New-Key '1234'
$vault = Protect-Budget $key $data
$opened = Unprotect-Budget $vault '1234'
$rent = $opened.Data.items | Where-Object { $_.day -eq 31 }
Check 'správný PIN trezor otevře' $opened.Data.items.Count 3
Check 'čeština a haléře cestu přežijí' "$($rent.name) $($rent.amount)" 'Nájem u paní Šťastné 15000.5'
Check 'špatný PIN ho neotevře' ($null -eq (Unprotect-Budget $vault '1235')) $true
Check 'v trezoru není nic čitelného' ([Text.Encoding]::UTF8.GetString($vault) -match 'Nájem|Bydlení|amount') $false
Check 'každé uložení má jiný IV' ([Convert]::ToBase64String((Protect-Budget $key $data)) -eq [Convert]::ToBase64String($vault)) $false
$broken = [byte[]]$vault.Clone()
$broken[60] = $broken[60] -bxor 1
Check 'pozměněný trezor neprojde' ($null -eq (Unprotect-Budget $broken '1234')) $true

$file = Join-Path $temp 'data.bin'
Save-Budget $file $key $data
Save-Budget $file $key $data   # podruhé už se přepisuje existující soubor
Check 'soubor na disku je navíc zabalený v DPAPI' (Test-Vault ([IO.File]::ReadAllBytes($file))) $false
Check 'po uložení nezbyde rozepsaný soubor' (Test-Path "$file.new") $false
$opened = Open-Budget $file '1234'
Check 'Open-Budget přečte, co Save-Budget uložil' "$($opened.Data.items.Count) $($opened.Backup)" '3 False'
Check 'Open-Budget se špatným PINem' ($null -eq (Open-Budget $file '0000')) $true
[IO.File]::WriteAllBytes($file, $vault)
Check 'záloha položená na místo dat jde otevřít' (Open-Budget $file '1234').Backup $true

# ---- Měsíce ----

Check 'opakované položky jsou v každém měsíci' "$(@(Get-MonthItems $data '2026-01').Count) $(@(Get-MonthItems $data '2026-03').Count)" '2 2'
Check 'jednorázová jen ve svém' (@(Get-MonthItems $data '2026-02').Count) 3
Check 'před začátkem nic není' (@(Get-MonthItems $data '2025-12').Count) 0

$rent = Get-MonthItems $data '2026-03' | Where-Object { $_.cat -eq 'Bydlení' }
Set-Entry $data '2026-03' @{ id = $rent.id; name = 'Nájem'; amount = 16000; day = 31; to = ''; cat = 'Bydlení'; monthly = $true }
Check 'zdražení od března nepřepíše únor' "$((Get-Summary $data '2026-02').Expenses) $((Get-Summary $data '2026-03').Expenses)" '24990.5 16000'

Set-Paid $data '2026-03' $rent.id $true
Check 'zaplaceno platí jen pro svůj měsíc' "$((Get-Summary $data '2026-03').Unpaid) $((Get-Summary $data '2026-04').Unpaid)" '0 16000'
Set-Entry $data '2026-03' @{ id = $rent.id; name = 'Nájem'; amount = 16500; day = 31; to = ''; cat = 'Bydlení'; monthly = $true }
Check 'úprava nechá platbu zaplacenou' "$(Test-Paid $data '2026-03' $rent.id) $((Get-Summary $data '2026-03').Expenses)" 'True 16500'

Remove-Entry $data '2026-05' $rent.id
Check 'smazání od května nechá duben' "$((Get-Summary $data '2026-04').Expenses) $((Get-Summary $data '2026-05').Expenses)" '16500 0'
Check 'příjem se mezi výdaje nepočítá' (Get-Summary $data '2026-05').Income 50000
Check 'rok má dvanáct měsíců' "$(@(Get-Year $data 2026).Count) $((Get-Year $data 2026)[1].Expenses)" '12 24990.5'
Check 'typy od největšího' ((Get-Breakdown (New-DemoBudget) (Get-MonthKey ([DateTime]::Today)))[0].Name) 'Bydlení'

Check 'částka s mezerou a čárkou' (ConvertTo-Amount '1 499,90') '1499.90'
Check 'nejasná částka 1.500 neprojde' ($null -eq (ConvertTo-Amount '1.500')) $true
Check 'nula ani text neprojdou' "$($null -eq (ConvertTo-Amount '0')) $($null -eq (ConvertTo-Amount 'hodně'))" 'True True'
Check 'splatnost 31. je v únoru 28.' (Get-DueDate '2026-02' 31).ToString('yyyy-MM-dd') '2026-02-28'
Check 'peníze česky' (Spaces (Format-Money 15000.5)) '15 000,50 Kč'
Check 'název měsíce' (Format-Month '2026-10') 'Říjen 2026'
Check 'leden minus jedna je loňský prosinec' (Add-Month '2026-01' -1) '2025-12'

# ---- Okno ----

function Press([string]$key) {
    $source = [Windows.PresentationSource]::FromVisual($window)
    $e = [Windows.Input.KeyEventArgs]::new([Windows.Input.Keyboard]::PrimaryDevice, $source, 0, [Windows.Input.Key]$key)
    $e.RoutedEvent = [Windows.Input.Keyboard]::PreviewKeyDownEvent
    $window.RaiseEvent($e)
}
function Enter([string]$pin) { foreach ($digit in $pin.ToCharArray()) { Press "D$digit" } }
function Click($button) { $button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent)) }
function Shown($view) { $view.Visibility -eq 'Visible' }

$appFile = Join-Path $temp 'app.bin'
$walk = {
    Check 'první spuštění chce nový PIN' $ui.LockPrompt.Text 'Zvol si čtyřmístný PIN'
    Enter '1234'
    Check 'čtvrtá číslice odešle sama, chce potvrzení' $ui.LockPrompt.Text 'Zadej ho ještě jednou'
    Enter '1235'
    Check 'jiný PIN napodruhé neprojde' "$($ui.LockStatus.Text) $(Test-Path $appFile)" 'PINy se liší. Zkus to znovu od začátku. False'
    Enter '1234'
    Enter '1234'
    Check 'stejný PIN dvakrát otevře přehled a založí soubor' "$(Shown $ui.MainView) $(Shown $ui.LockView) $(Test-Path $appFile)" 'True False True'

    Click $ui.AddButton
    $ui.NameBox.Text = 'Nájem'
    $ui.AmountBox.Text = 'hodně'
    Click $ui.SaveButton
    Check 'nesmyslná částka se neuloží' "$(Shown $ui.EditorView) $($ui.Rows.Items.Count)" 'True 0'
    $ui.AmountBox.Text = '15 000'
    $ui.DayBox.Text = '5'
    ($ui.Categories.Children | Where-Object { $_.Content -eq 'Bydlení' }).IsChecked = $true
    Press 'Return'
    Check 'Enter položku uloží' "$(Shown $ui.EditorView) $($ui.Rows.Items.Count) $(Spaces $ui.ExpensesText.Text)" 'False 1 15 000 Kč'
    Check 'typ se propíše do grafu' "$($ui.Breakdown.Items[0].Name) $($ui.Breakdown.Items[0].Share)" 'Bydlení 100 %'

    Switch-Paid $ui.Rows.Items[0] $true
    Check 'kolečko platbu zaplatí' "$($ui.PaidText.Text), zbývá $($ui.UnpaidText.Text)" 'zaplaceno 1 z 1, zbývá 0 Kč'

    Click $ui.LockButton
    Check 'zamknutí schová přehled a zahodí data z paměti' "$(Shown $ui.LockView) $(Shown $ui.MainView) $($null -eq $state.Data) $($ui.Rows.Items.Count)" 'True False True 0'
    Enter '9999'
    Check 'špatný PIN neodemkne' "$($ui.LockStatus.Text) $(Shown $ui.LockView)" 'Špatný PIN. True'
    Press 'D7'
    Press 'Back'
    Enter '1234'
    Check 'správný PIN vrátí uložená data' "$(Shown $ui.MainView) $($ui.Rows.Items.Count) $($ui.PaidText.Text)" 'True 1 zaplaceno 1 z 1'

    Click $ui.NextButton
    Check 'další měsíc: platba se opakuje, zaplacená ještě není' "$($ui.Rows.Items.Count) $($ui.PaidText.Text)" '1 zaplaceno 0 z 1'

    Open-Editor $ui.Rows.Items[0]
    Click $ui.DeleteButton
    Check 'první Smazat se jen zeptá' "$($ui.DeleteButton.Content) $($ui.Rows.Items.Count)" 'Opravdu smazat? 1'
    Click $ui.DeleteButton
    Click $ui.PrevButton
    Check 'smazání od dalšího měsíce nechá ten předchozí' "$($state.Data.items.Count) $($ui.Rows.Items.Count)" '1 1'

    Click $ui.PinButton
    Enter '4321'
    Enter '4321'
    Click $ui.LockButton
    Enter '1234'
    Check 'starý PIN po změně neplatí' $ui.LockStatus.Text 'Špatný PIN.'
    Enter '4321'
    Check 'nový PIN platí' "$(Shown $ui.MainView) $($ui.Rows.Items.Count)" 'True 1'
    $onDisk = [IO.File]::ReadAllBytes($appFile)
    Check 'soubor aplikace není čitelný ani bez DPAPI otevřený' "$([Text.Encoding]::UTF8.GetString($onDisk) -match 'Nájem|Bydlení') $(Test-Vault $onDisk)" 'False False'
}

# Okno otevře až Mesec.ps1 níže; časovač počká, až bude vidět, a projde ho.
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$starter = [Windows.Threading.DispatcherTimer]::new()
$starter.Interval = [TimeSpan]::FromMilliseconds(200)
$starter.Add_Tick({
    if (-not ($window -and $window.IsLoaded)) { return }
    $starter.Stop()
    try { & $walk }
    catch { $script:fail++; Note "FAIL  průchod oknem spadl na řádku $($_.InvocationInfo.ScriptLineNumber): $_" }
    finally { $window.Close() }
})
$starter.Start()
. (Join-Path $root 'Mesec.ps1') -DataPath $appFile

$script:lines
Remove-Item -Recurse -Force $temp
if ($script:fail) { "`n$($script:fail) chyb" } else { "`nVšechno prošlo." }
exit $script:fail
