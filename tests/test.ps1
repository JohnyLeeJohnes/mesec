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

. (Join-Path $root 'Data.ps1')

# ---- Soubory ----

# Bez BOM čte PowerShell 5.1 skript jako ANSI a rozbije češtinu.
foreach ($source in Get-ChildItem $root, "$root\tests", "$root\tools" -Filter *.ps1) {
    $bytes = [IO.File]::ReadAllBytes($source.FullName)
    Check "$($source.Name) je UTF-8 s BOM" ('{0:X2}{1:X2}{2:X2}' -f $bytes[0], $bytes[1], $bytes[2]) 'EFBBBF'
}

# ---- Šifrování ----

$data = New-Mesec
Set-Entry $data '2026-01' @{ name = 'Nájem u paní Šťastné'; amount = 15000.5; day = 31; to = 'Pronajímatel'; cat = 'Bydlení'; until = '' }
Set-Entry $data '2026-01' @{ name = 'Výplata'; amount = 50000; day = 10; to = ''; cat = $incomeCategory; until = '' }
Set-Entry $data '2026-02' @{ name = 'Splátka pračky'; amount = 9990; day = 14; to = ''; cat = 'Splátky'; until = '2026-03' }

$key = New-Key '1234'
$vault = Protect-Mesec $key $data
$opened = Unprotect-Mesec $vault '1234'
$rent = $opened.Data.items | Where-Object { $_.day -eq 31 }
Check 'správný PIN trezor otevře' $opened.Data.items.Count 3
Check 'čeština a haléře cestu přežijí' "$($rent.name) $($rent.amount)" 'Nájem u paní Šťastné 15000.5'
Check 'špatný PIN ho neotevře' ($null -eq (Unprotect-Mesec $vault '1235')) $true
Check 'v trezoru není nic čitelného' ([Text.Encoding]::UTF8.GetString($vault) -match 'Nájem|Bydlení|amount') $false
Check 'každé uložení má jiný IV' ([Convert]::ToBase64String((Protect-Mesec $key $data)) -eq [Convert]::ToBase64String($vault)) $false
$broken = [byte[]]$vault.Clone()
$broken[60] = $broken[60] -bxor 1
Check 'pozměněný trezor neprojde' ($null -eq (Unprotect-Mesec $broken '1234')) $true

$file = Join-Path $temp 'data.bin'
Save-Mesec $file $key $data
Save-Mesec $file $key $data   # podruhé už se přepisuje existující soubor
Check 'soubor na disku je navíc zabalený v DPAPI' (Test-Vault ([IO.File]::ReadAllBytes($file))) $false
Check 'po uložení nezbyde rozepsaný soubor' (Test-Path "$file.new") $false
$opened = Open-Mesec $file '1234'
Check 'Open-Mesec přečte, co Save-Mesec uložil' "$($opened.Data.items.Count) $($opened.Backup)" '3 False'
Check 'Open-Mesec se špatným PINem' ($null -eq (Open-Mesec $file '0000')) $true
[IO.File]::WriteAllBytes($file, $vault)
Check 'záloha položená na místo dat jde otevřít' (Open-Mesec $file '1234').Backup $true

# ---- Měsíce ----

function Spent([string[]]$months) { "$(foreach ($month in $months) { (Get-Summary $data $month).Expenses })" }

Check 'platba bez konce je v každém dalším měsíci' "$(@(Get-MonthItems $data '2026-01').Count) $(@(Get-MonthItems $data '2031-07').Count)" '2 2'
Check 'platba s koncem je vidět jen do něj' "$(@(Get-MonthItems $data '2026-02').Count) $(@(Get-MonthItems $data '2026-03').Count) $(@(Get-MonthItems $data '2026-04').Count)" '3 3 2'
Check 'před začátkem nic není' (@(Get-MonthItems $data '2025-12').Count) 0

$rent = (Get-MonthItems $data '2026-03' | Where-Object { $_.cat -eq 'Bydlení' }).id
Set-Entry $data '2026-03' @{ id = $rent; name = 'Nájem'; amount = 16000; day = 31; to = ''; cat = 'Bydlení'; until = '' }
Check 'zdražení od března nepřepíše únor' (Spent '2026-02', '2026-03', '2026-04') '24990.5 25990 16000'
Set-Entry $data '2026-03' @{ id = $rent; name = 'Nájem'; amount = 16500; day = 31; to = ''; cat = 'Bydlení'; until = '2026-12' }
Check 'druhá úprava v témže měsíci verzi nahradí' "$($data.items.Count) $(Spent '2026-03')" '4 26490'
Check 'konec platí pro celou platbu' "$(Get-EntryEnd $data $rent) $(Spent '2026-12', '2027-01')" '2026-12 16500 0'

Skip-Entry $data '2026-05' $rent
Check 'smazání jen pro květen nechá duben i červen' (Spent '2026-04', '2026-05', '2026-06') '16500 0 16500'
Set-Entry $data '2026-04' @{ id = $rent; name = 'Nájem'; amount = 17000; day = 31; to = ''; cat = 'Bydlení'; until = '' }
Check 'pozdější úprava vynechaný květen nevrátí' "$(Spent '2026-05', '2026-06', '2027-01') [$(Get-EntryEnd $data $rent)]" '0 17000 17000 []'

Remove-Entry $data '2026-07' $rent
Check 'smazání od července nechá červen' "$(Spent '2026-06', '2026-07') $(Get-EntryEnd $data $rent)" '17000 0 2026-06'
Set-Entry $data '2026-02' @{ id = $rent; name = 'Nájem'; amount = 15500; day = 31; to = ''; cat = 'Bydlení'; until = '2026-04' }
Check 'změna v únoru platí i pro pozdější verze' (Spent '2026-01', '2026-02', '2026-04', '2026-05') '15000.5 25490 15500 0'

Check 'příjem se mezi výdaje nepočítá' (Get-Summary $data '2026-05').Income 50000
Check 'rok má dvanáct měsíců' "$(@(Get-Year $data 2026).Count) $((Get-Year $data 2026)[1].Month) $((Get-Year $data 2026)[1].Expenses)" '12 2026-02 25490'
Check 'typy od největšího' ((Get-Breakdown (New-DemoMesec) (Get-MonthKey ([DateTime]::Today)))[0].Name) 'Bydlení'

# Soubor z verze, která znala zaškrtávání a jednorázové položky.
$legacy = ConvertFrom-MesecJson '{"items":[{"id":"a","name":"Dárek","amount":1500,"day":22,"to":"","cat":"Ostatní","from":"2026-01","until":"2026-01"}],"paid":["2026-01|a"]}'
Check 'starší data: zaškrtnutí se zahodí' "$($legacy.skipped.Count) $($legacy.ContainsKey('paid'))" '0 False'
Check 'starší data: jednorázová položka je platba, která končí hned' "$(@(Get-MonthItems $legacy '2026-01').Count) $(@(Get-MonthItems $legacy '2026-02').Count)" '1 0'

Check 'částka s mezerou a čárkou' (ConvertTo-Amount '1 499,90') '1499.90'
Check 'nejasná částka 1.500 neprojde' ($null -eq (ConvertTo-Amount '1.500')) $true
Check 'nula ani text neprojdou' "$($null -eq (ConvertTo-Amount '0')) $($null -eq (ConvertTo-Amount 'hodně'))" 'True True'
Check 'peníze česky' (Spaces (Format-Money 15000.5)) '15 000,50 Kč'
Check 'název měsíce' (Format-Month '2026-10') 'Říjen 2026'
Check 'konec platby česky' (Format-Until '2026-10') 'do října 2026'
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
    $days = @($ui.PickerDays.Children)
    Click $ui.DayButton
    Check 'vybírátko dne se otevře na dnešku' "$($ui.DayPicker.IsOpen) $($days.Count) $(($days | Where-Object { $_.IsChecked }).Tag)" "True 31 $([DateTime]::Today.Day)"
    Press 'Return'
    Check 'Enter nad otevřeným vybírátkem formulář neuloží' "$(Shown $ui.EditorView) $($ui.Rows.Items.Count)" 'True 0'
    Click $days[4]
    Check 'kliknutí na den ho nastaví' "$($ui.DayPicker.IsOpen) $($ui.DayButton.Content)" 'False 5.'
    ($ui.Categories.Children | Where-Object { $_.Content -eq 'Bydlení' }).IsChecked = $true
    Press 'Return'
    Check 'Enter položku uloží' "$(Shown $ui.EditorView) $($ui.Rows.Items.Count) $($ui.Rows.Items[0].Day) $(Spaces $ui.ExpensesText.Text)" 'False 1 5. 15 000 Kč'
    Check 'typ se propíše do grafu' "$($ui.Breakdown.Items[0].Name) $($ui.Breakdown.Items[0].Share)" 'Bydlení 100 %'
    Check 'platba bez konce nemá poznámku' "[$($ui.Rows.Items[0].Note)]" '[]'

    Click $ui.LockButton
    Check 'zamknutí schová přehled a zahodí data z paměti' "$(Shown $ui.LockView) $(Shown $ui.MainView) $($null -eq $state.Data) $($ui.Rows.Items.Count)" 'True False True 0'
    Enter '9999'
    Check 'špatný PIN neodemkne' "$($ui.LockStatus.Text) $(Shown $ui.LockView)" 'Špatný PIN. True'
    Press 'D7'
    Press 'Back'
    Enter '1234'
    Check 'správný PIN vrátí uložená data' "$(Shown $ui.MainView) $($ui.Rows.Items.Count)" 'True 1'

    # Měsíce: 0 = dnešní, 1 a 2 = další dva.
    $next = Add-Month $state.Month 1
    Click $ui.NextButton
    Check 'další měsíc: platba je tam taky' $ui.Rows.Items.Count 1

    Open-Editor $ui.Rows.Items[0]
    Check 'u platby je nejdřív jen Smazat' "$(Shown $ui.DeleteButton) $(Shown $ui.DeleteChoices)" 'True False'
    Click $ui.DeleteButton
    Check 'Smazat se zeptá, co smazat' "$(Shown $ui.DeleteButton) $(Shown $ui.DeleteChoices) $($ui.Rows.Items.Count)" 'False True 1'
    Click $ui.DeleteMonthButton
    Check 'smazání jen pro měsíc ho vyprázdní' "$(Shown $ui.EditorView) $($ui.Rows.Items.Count)" 'False 0'
    Click $ui.NextButton
    Check 'a v dalším měsíci platba zase je' $ui.Rows.Items.Count 1

    Open-Editor $ui.Rows.Items[0]
    Click $ui.DeleteButton
    Click $ui.DeleteOnwardButton
    Click $ui.NextButton
    Check 'smazání od měsíce dál platí i pro ty další' $ui.Rows.Items.Count 0
    Click $ui.TodayButton
    Check 'starší měsíce po smazání zůstanou a ukazují konec' "$($ui.Rows.Items.Count) $($ui.Rows.Items[0].Note)" "1 $(Format-Until $next)"

    # Vybírátko měsíce: konec platby se nepíše, volí se.
    $shown = Get-MonthStart $state.Month
    $chips = @($ui.PickerMonths.Children)
    Open-Editor $ui.Rows.Items[0]
    Check 'formulář ukáže konec platby' $ui.UntilButton.Content (Format-Month $next)
    Click $ui.UntilButton
    Check 'vybírátko se otevře na konci platby' "$($ui.MonthPicker.IsOpen) $($ui.PickerYear.Text) $(($chips | Where-Object { $_.IsChecked }).Tag)" "True $((Get-MonthStart $next).Year) $((Get-MonthStart $next).Month)"
    if ($state.Pick.Year -gt $shown.Year) { Click $ui.PickerPrevYear }
    Check 'měsíce před zobrazeným zvolit nejdou' "$(@($chips | Where-Object { $_.IsEnabled }).Count) $($ui.PickerPrevYear.IsEnabled)" "$(13 - $shown.Month) False"
    Press 'Escape'
    Check 'Esc zavře vybírátko, formulář nechá' "$($ui.MonthPicker.IsOpen) $(Shown $ui.EditorView) $($ui.UntilButton.Content)" "False True $(Format-Month $next)"
    Click $ui.UntilButton
    Click $ui.PickerNextYear
    Click $chips[5]
    Check 'kliknutí na měsíc nastaví konec' "$($ui.MonthPicker.IsOpen) $($ui.UntilButton.Content)" "False Červen $((Get-MonthStart $next).Year + 1)"
    Click $ui.UntilButton
    Click $ui.PickerClearButton
    Check 'konec jde zase zrušit' $ui.UntilButton.Content 'Bez omezení'
    Press 'Return'
    Click $ui.NextButton
    Click $ui.NextButton
    Check 'platba bez konce běží dál' "$(Shown $ui.EditorView) $($ui.Rows.Items.Count)" 'False 1'
    Click $ui.PrevButton
    Check 'jen vynechaný měsíc zůstává prázdný' $ui.Rows.Items.Count 0

    Click $ui.TodayButton
    Click $ui.MonthButton
    Check 'v záhlaví se měsíc jen volí, zrušit nejde' "$(Shown $ui.PickerClearButton) $(@($chips | Where-Object { $_.IsEnabled }).Count)" 'False 12'
    Click $ui.PickerPrevYear
    Click $chips[0]
    Check 'vybírátko v záhlaví přejde na zvolený měsíc' "$($state.Month) $($ui.MonthText.Text)" "$($shown.Year - 1)-01 Leden $($shown.Year - 1)"
    Click $ui.TodayButton

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
