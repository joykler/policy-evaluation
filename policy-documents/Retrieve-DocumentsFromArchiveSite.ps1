using namespace Microsoft.PowerShell.Commands
using namespace System.Net


$InformationPreference = 'Continue'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'Ignore'

$PSDefaultParameterValues = @{
    'Write-Verbose:Verbose' = $true

    'Add-Member:MemberType' = 'ScriptMethod'
    'Add-Member:PassThru'   = $true
}

$PSStyle.OutputRendering = 'Ansi'



#region -- Declare: $Logging --
$global:Logging = [PSCustomObject]::new()
& {
    function Add-LoggingMethod([string] $Name, [scriptblock] $Method) {

        $global:Logging = $global:Logging | Add-Member -Name $Name -Value $Method
    }

    Add-LoggingMethod 'Info_StartedDownloadingAllFiles' -Method {

        $S = $PSStyle.Foreground.BrightWhite + $PSStyle.Bold + $PSStyle.Italic
        $R = $PSStyle.Reset

        Write-Information $($S + 'Started downloading all files...' + $R)
    }

    Add-LoggingMethod 'Info_GotResultsFromSearchPage' -Method {

        param([int] $CurrentPageNr, [int] $MaximumPageNr)

        $S = $PSStyle.Foreground.White + $PSStyle.Italic
        $R = $PSStyle.Reset

        Write-Information $($S + " - Search[$MaximumPageNr] => Got results from page $CurrentPageNr" + $R)
    }

    Add-LoggingMethod 'Info_PathDetermined' -Method {

        param([string] $dir_relpath, [string] $file)

        $S = $PSStyle.Foreground.BrightCyan + $PSStyle.Bold
        $F = $PSStyle.Foreground.White + $PSStyle.BoldOff + $PSStyle.Italic
        $R = $PSStyle.Reset

        Write-Information $($S + " * Path determined: $F[ $($dir_relpath.Length) ]> $($file.Length)" + $R)
    }

    Add-LoggingMethod 'Info_FileDownloaded' -Method {

        param([string] $dir_relpath, [string] $file)

        $S = $PSStyle.Foreground.Green + $PSStyle.Bold
        $F = $PSStyle.Foreground.White + $PSStyle.BoldOff + $PSStyle.Italic
        $R = $PSStyle.Reset

        Write-Information $($S + " * File downloaded: $F[ $dir_relpath ]> $file" + $R)
    }

    Add-LoggingMethod 'Warn_FileAllreadyExists' -Method {

        param([string] $dir_relpath, [string] $file)

        $S = $PSStyle.Foreground.BrightYellow + $PSStyle.Bold
        $F = $PSStyle.Foreground.White + $PSStyle.BoldOff + $PSStyle.Italic
        $R = $PSStyle.Reset

        Write-Warning $($S + " ! File allready exists: $F[ $dir_relpath ]> $file" + $R)
    }

    Add-LoggingMethod 'Warn_ConnectionFailedRetryingAfterSleep' -Method {

        $S = $PSStyle.Foreground.BrightYellow + $PSStyle.Bold
        $F = $PSStyle.Foreground.White + $PSStyle.BoldOff + $PSStyle.Italic
        $R = $PSStyle.Reset

        Write-Warning $($S + " ! Connection error: $F retrying after sleep..." + $R)
    }

}
#endregion

#region -- Declare: New-Search --
function New-Search ([int] $StartFromPageNr = 1) {

    $Search = [PSCustomObject] @{

        CurrentPageNr = $StartFromPageNr
        MaximumPageNr = -1

        Headers       = @{
            'Accept'             = '*/*'
            'Accept-Encoding'    = 'gzip, deflate, br, zstd'
            'Accept-Language'    = 'en-GB,en;q=0.9,en-US;q=0.8,nl;q=0.7'
            'Origin'             = 'https://rijksoverheid.sitearchief.nl'
            'Referer'            = 'https://rijksoverheid.sitearchief.nl/'
            'Sec-Fetch-Dest'     = 'empty'
            'Sec-Fetch-Mode'     = 'cors'
            'Sec-Fetch-Site'     = 'same-origin'
            'X-Requested-With'   = 'XMLHttpRequest'
            'sec-ch-ua'          = "`"Microsoft Edge`";v=`"135`", `"Not-A.Brand`";v=`"8`", `"Chromium`";v=`"135`""
            'sec-ch-ua-mobile'   = '?0'
            'sec-ch-ua-platform' = "`"Windows`""
        }

        BodyFormat    = @(
            'type=advsearch',
            'search-words-and=',
            'search-words-or=Cara%C3%AFbisch+Caribisch+Carabisch',
            'search-words-exact=',
            'search-words-except=',
            'search-site=all',
            'search-site-url=http%3A%2F%2F',
            'search-fields=title%2Ccontent',
            'search-types=pdf%2Cword%2Cexcel',
            'search-date-from=',
            'search-date-to=',
            'page={0}'
        ) -join '&'
    }



    $Search = $Search | Add-Member -MemberType ScriptProperty -Name 'HasFinishedPages' -Value {

        return ($this.MaximumPageNr -gt 0) -and ($this.CurrentPageNr -gt $this.MaximumPageNr)
    }



    $Search = $Search | Add-Member -Name 'GetResultsFromNextPage' -Value {

        if ($this.HasFinishedPages) {
            throw [System.InvalidOperationException] $('The search has finished getting the results from all pages. Current: {0}; Maximum: {1}' -f $this.CurrentPageNr, $this.MaximumPageNr)
        }

        $WebSession = [WebRequestSession]::new()
        $WebSession.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36 Edg/135.0.0.0'

        $SearchArgs = @{
            Uri         = 'https://rijksoverheid.sitearchief.nl/search.php'
            Method      = 'POST'
            ContentType = 'application/x-www-form-urlencoded; charset=UTF-8'
            WebSession  = $WebSession
            Headers     = $this.Headers
            Body        = $this.BodyFormat -f $this.CurrentPageNr
        }

        $Response = Invoke-WebRequest @SearchArgs
        if ($Response.StatusCode -ne 200) {
            throw [System.InvalidOperationException] $("Invalid response {0} - {1}`n for page nr: {2}`n from uri: {3}" -f $Response.StatusCode, $Response.StatusDescription, $this.CurrentPageNr, $SearchArgs.Uri)
        }

        if ($this.MaximumPageNr -lt 0) {
            if (($Response.Links[-1].id -eq 'lnkLastPage') -and ($Response.Links[-1].href -match 'javascript:archiefweb\.switch_to_page\((?<MAX_PAGE>\d+)\)')) {
                $this.MaximumPageNr = [int] $Matches.MAX_PAGE
            }
        }

        $global:Logging.Info_GotResultsFromSearchPage($this.CurrentPageNr, $this.MaximumPageNr)
        $this.CurrentPageNr++

        return $Response.Links
    }

    return $Search
}
#endregion



$Logging.Info_StartedDownloadingAllFiles()

$Search = New-Search -StartFromPageNr 1
while (-not $Search.HasFinishedPages) {

    $Search.GetResultsFromNextPage() |
        Where-Object href -Match '^http(s)?:/' |
        ForEach-Object href |
        Where-Object {
            $_ -match 'https://www\.rijksoverheid\.nl/binaries/rijksoverheid/documenten/(?<DIR>.*)/(?<File>.*)$'
        } |
        ForEach-Object {
            try {
                $href = $_

                $parsed = @{
                    dir  = $Matches.DIR
                    file = $Matches.FILE
                }

                $changed = @{}
                foreach ($item in $parsed.GetEnumerator()) {
                    $value = [uri]::UnescapeDataString($item.Value)

                    $value = $value -replace 'beleidsnota-s', 'beleidsnotas'

                    $changed.Add($item.Key, $value)
                }

                $file = $changed.file
                $file_base = [System.IO.Path]::GetFileNameWithoutExtension($file)

                $dir_relpath = $changed.dir -replace "/$([regex]::Escape($file_base))", ''
                $dir_abspath = Join-Path "$PSScriptRoot\Archive" -ChildPath $dir_relpath

                $file_abspath = Join-Path $dir_abspath -ChildPath $file
                $Logging.Info_PathDetermined($dir_relpath, $file)

                if (-not $(Test-Path $dir_abspath)) {
                    mkdir $dir_abspath -ErrorAction Ignore | Out-Null
                }

                if ($(Test-Path $file_abspath -PathType Leaf)) {
                    $Logging.Warn_FileAllreadyExists($dir_relpath, $file)

                } else {
                    try {
                        Invoke-WebRequest -Uri $href -OutFile $file_abspath -TimeoutSec 0
                        $Logging.Info_FileDownloaded($dir_relpath, $file)

                    } catch [Http.HttpRequestException] {
                        if ($_.Exception.HttpRequestError -eq 'ConnectionError') {
                            $Logging.Warn_ConnectionFailedRetryingAfterSleep()

                            Start-Sleep -Seconds 3

                            Invoke-WebRequest -Uri $href -OutFile $file_abspath -TimeoutSec 0
                            $Logging.Info_FileDownloaded($dir_relpath, $file)

                        } else {
                            throw $_
                        }
                    }
                }

            } catch {
                Write-Error $_ -ErrorAction Continue
            }
        }
}
