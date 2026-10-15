# Translations: the same catalogs (www/i18n/<language>.json) serve the page and
# the messages of the server. The page sends its language in X-Panel-Lang; the
# console of the panel speaks the language of Windows.

Set-StrictMode -Version 1.0

$script:CatalogDir = ''
$script:Catalogs = @{}
$script:Languages = @()
# Language of the request being served. The panel is single threaded, so one
# variable is enough; Start-Panel resets it after every request.
$script:Language = 'en'

function Initialize-I18n {
    param([Parameter(Mandatory = $true)][string]$Directory)

    $script:CatalogDir = $Directory
    $script:Catalogs = @{}
    $script:Languages = @()

    $index = Read-TextFileUtf8 (Join-Path $Directory 'index.json')
    if ([string]::IsNullOrWhiteSpace($index)) { return }
    foreach ($item in ($index | ConvertFrom-Json)) {
        if ([string]$item.code -cmatch '^[a-z]{2}(-[A-Z]{2})?\z') { $script:Languages += [string]$item.code }
    }
}

# A supported language for whatever the caller names: "zh", "pt-PT", "ru-RU"
# and the like are mapped, an unknown one gives English.
function Resolve-Language {
    param([string]$Requested)

    $name = ([string]$Requested).Trim()
    if ($name.Length -eq 0) { return 'en' }

    foreach ($code in $script:Languages) {
        if ($code -ieq $name) { return $code }
    }
    $base = ($name -split '[-_]')[0].ToLowerInvariant()
    foreach ($code in $script:Languages) {
        if ($code -ieq $base -or ($code -split '-')[0] -ieq $base) { return $code }
    }
    return 'en'
}

function Get-Catalog {
    param([string]$Code)

    if ($script:Catalogs.ContainsKey($Code)) { return $script:Catalogs[$Code] }

    $catalog = @{}
    if ($script:Languages -contains $Code) {
        $raw = Read-TextFileUtf8 (Join-Path $script:CatalogDir "$Code.json")
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            foreach ($entry in ($raw | ConvertFrom-Json).PSObject.Properties) { $catalog[$entry.Name] = [string]$entry.Value }
        }
    }
    $script:Catalogs[$Code] = $catalog
    return $catalog
}

# The text of a key in the current language, with {0}, {1} ... filled in.
# English stands in for a missing key, and the key itself for a missing catalog.
function T {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(ValueFromRemainingArguments = $true)][object[]]$Arguments
    )

    $text = $null
    foreach ($code in @($script:Language, 'en')) {
        $catalog = Get-Catalog $code
        if ($catalog.ContainsKey($Key)) { $text = $catalog[$Key]; break }
    }
    if ($null -eq $text) { return $Key }
    if ($Arguments -and $Arguments.Count -gt 0) { return [string]::Format($text, [object[]]$Arguments) }
    return $text
}
