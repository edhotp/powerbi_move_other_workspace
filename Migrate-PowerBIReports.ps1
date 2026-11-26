#requires -Version 7.0
<#
.SYNOPSIS
Copies or moves Power BI reports between workspaces on the same capacity.
.DESCRIPTION
Read-only preview by default. Use -Apply to execute. Copy retains source
reports; Move deletes them only after all selected targets are verified.
Both modes retain original semantic models and never change capacity.
IncludeSemanticModels imports related models into the target and keeps their
original data source references. Move then requires target source validation.
All selected reports must have verified local PBIX backups before mutation.
Uses interactive user login through MicrosoftPowerBIMgmt.Profile 1.3.84+.
Every logical activity requires explicit confirmation. Move additionally
requires cutover acceptance and typed approval for each source report.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SourceWorkspace,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TargetWorkspace,

    [guid[]]$ReportIds,

    [ValidateSet('Copy', 'Move')]
    [string]$Mode = 'Copy',

    [switch]$Apply,

    [switch]$WhatIf,

    [switch]$IncludeSemanticModels,

    [ValidateNotNullOrEmpty()]
    [string]$BackupDirectory = (Join-Path $PSScriptRoot 'Backups'),

    [ValidateSet('IncludeModel', 'LiveConnect')]
    [string]$BackupDownloadType = 'IncludeModel',

    [string]$StatePath = (Join-Path $PSScriptRoot 'migration-state.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$apiRoot = 'https://api.powerbi.com/v1.0/myorg'

function Request-ActivityConfirmation {
    param(
        [string]$Activity,
        [string]$Details,
        [string]$RequiredText = 'LANJUT'
    )
    Write-Host "`n[$Activity] $Details"
    $answer = Read-Host "[$Activity] Ketik tepat '$RequiredText' untuk menyetujui; Enter/jawaban lain membatalkan"
    if ($answer -cne $RequiredText) {
        throw [OperationCanceledException]::new("Dibatalkan pada aktivitas '$Activity'. Aktivitas tersebut tidak dijalankan; hasil tahap sebelumnya tetap tersimpan. Gunakan state yang sama setelah ditinjau.")
    }
}

function Get-PowerBIHeaders {
    $headers = Get-PowerBIAccessToken -ErrorAction Stop
    if ($headers -isnot [System.Collections.IDictionary] -or
        [string]$headers['Authorization'] -notmatch '^Bearer \S+$') {
        throw 'Respons token sesi Power BI tidak valid. Login ulang menggunakan akun pengguna yang memiliki akses workspace.'
    }
    return $headers
}

function Invoke-PowerBIApi {
    param(
        [ValidateSet('GET', 'POST', 'DELETE')]
        [string]$Method,
        [string]$Path,
        [System.Collections.IDictionary]$Body,
        [switch]$AllowNotFound,
        [string]$OutFile,
        [System.Collections.IDictionary]$Form,
        [switch]$AllowAccepted,
        [switch]$RawResponse
    )
    for ($attempt = 0; $attempt -le 3; $attempt++) {
        $request = @{
            Uri = "$script:apiRoot/$Path"
            Method = $Method
            Headers = Get-PowerBIHeaders
            TimeoutSec = 120
            MaximumRedirection = 0
            SkipHttpErrorCheck = $true
        }
        if ($null -ne $Body) {
            $request['ContentType'] = 'application/json; charset=utf-8'
            $request['Body'] = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 20 -Compress))
        }
        if ($null -ne $Form) {
            $request['Form'] = $Form
            $request['TimeoutSec'] = 1800
        }
        if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
            $request['OutFile'] = $OutFile
            $request['PassThru'] = $true
            $request['TimeoutSec'] = 1800
        }
        # A lost POST response may still have created a report. Never replay it.
        $response = Invoke-WebRequest @request
        $status = [int]$response.StatusCode
        if ($status -eq 200 -or ($AllowAccepted -and $status -eq 202)) {
            if ($RawResponse) { return $response }
            if ($Method -eq 'DELETE') { return }
            if (-not [string]::IsNullOrWhiteSpace($OutFile)) { return $response }
            $result = $response.Content | ConvertFrom-Json -AsHashtable
            if ($result -isnot [System.Collections.IDictionary]) {
                throw "Respons JSON $Method $Path tidak valid: HTTP 200 harus berisi object, bukan null atau array."
            }
            return $result
        }
        if ($Method -eq 'GET' -and $AllowNotFound -and $status -eq 404) { return $null }
        if ($Method -eq 'GET' -and $attempt -lt 3 -and $status -in @(429, 500, 502, 503, 504)) {
            $delay = [int][Math]::Pow(2, $attempt + 1)
            if ($response.Headers.ContainsKey('Retry-After')) {
                $seconds = 0
                if ([int]::TryParse([string]($response.Headers['Retry-After'] | Select-Object -First 1), [ref]$seconds)) {
                    $delay = [Math]::Max($delay, $seconds)
                }
            }
            Write-Warning "GET ${Path}: HTTP $status. Coba lagi setelah $delay detik."
            Start-Sleep -Seconds $delay
            continue
        }
        throw "Power BI API gagal: $Method $Path, HTTP $status. $($response.Content)"
    }
}

function Get-PowerBICollection {
    param([System.Collections.IDictionary]$Response, [string]$Label)
    if (-not $Response.ContainsKey('value') -or $Response['value'] -isnot [array]) {
        throw "Respons daftar $Label tidak valid: value harus berupa array objek."
    }
    foreach ($item in $Response['value']) {
        $id = [guid]::Empty
        if ($item -isnot [System.Collections.IDictionary] -or
            -not [guid]::TryParse([string]$item['id'], [ref]$id) -or $id -eq [guid]::Empty -or
            [string]::IsNullOrWhiteSpace($item['name'])) {
            throw "Respons daftar $Label tidak valid: setiap item harus memiliki id GUID dan name."
        }
    }
    return $Response['value']
}

function Get-PowerBIWorkspaces {
    $skip = 0
    do {
        $page = Invoke-PowerBIApi -Method GET -Path ('groups?$top=100&$skip={0}' -f $skip)
        $items = @(Get-PowerBICollection -Response $page -Label 'workspace')
        $items
        $skip += $items.Count
    } while ($items.Count -eq 100)
}

function Resolve-Workspace {
    param([object[]]$Workspaces, [string]$Identifier)
    $id = [guid]::Empty
    if ([guid]::TryParse($Identifier, [ref]$id)) {
        $matches = @($Workspaces | Where-Object { $_['id'] -eq $id.ToString() })
    } else {
        $matches = @($Workspaces | Where-Object { $_['name'] -eq $Identifier })
    }
    if ($matches.Count -ne 1) {
        throw "Workspace '$Identifier' ditemukan $($matches.Count) kali. Gunakan ID yang unik dan cek akses akun."
    }
    return $matches[0]
}

function Save-JsonFile {
    param([System.Collections.IDictionary]$Data, [string]$Path)
    $temporaryPath = "$Path.tmp"
    try {
        $Data | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporaryPath -Encoding utf8
        [IO.File]::Move($temporaryPath, $Path, $true)
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath
        }
    }
}

function Save-MigrationState {
    Save-JsonFile -Data $state -Path $script:resolvedStatePath
}

function Get-BackupFileInfo {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Backup lokal tidak ditemukan: $Path"
    }
    $length = (Get-Item -LiteralPath $Path).Length
    if ($length -eq 0) {
        throw "Backup lokal kosong: $Path"
    }
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        if (@($archive.Entries | Where-Object {
            $_.FullName.StartsWith('Report/', [StringComparison]::Ordinal) -and
            -not $_.FullName.EndsWith('/') -and $_.Length -gt 0
        }).Count -eq 0) {
            throw "Backup tidak memiliki bagian Report dalam paket PBIX. Export stub/format lain tidak dianggap backup lengkap: $Path"
        }
    } finally {
        $archive.Dispose()
    }
    return @{
        sizeBytes = $length
        sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
}

function Assert-LocalBackup {
    param([System.Collections.IDictionary]$Backup, [System.Collections.IDictionary]$Item)
    if ($null -eq $Backup -or $Backup['reportId'] -ne $Item['sourceReportId'] -or
        $Backup['name'] -cne $Item['name'] -or $Backup['datasetId'] -ne $Item['datasetId'] -or
        $Backup['downloadType'] -ne $BackupDownloadType -or [string]::IsNullOrWhiteSpace($Backup['path'])) {
        throw "Backup untuk '$($Item['name'])' belum ada atau metadata/downloadType tidak cocok. Sumber yang sudah hilang tidak boleh dianggap sudah dibackup."
    }
    $info = Get-BackupFileInfo -Path $Backup['path']
    if ($info['sizeBytes'] -ne $Backup['sizeBytes'] -or $info['sha256'] -ne $Backup['sha256']) {
        throw "Integritas backup '$($Item['name'])' gagal: ukuran atau SHA256 berubah. Penghapusan tidak dilanjutkan."
    }
}

function Save-ReportBackup {
    param([System.Collections.IDictionary]$Item, [string]$Directory)
    $fileName = ([guid]$Item['sourceReportId']).ToString() + '.pbix'
    $path = Join-Path $Directory $fileName
    $partialPath = "$path.partial"
    try {
        $response = Invoke-PowerBIApi -Method GET -Path "groups/$($source['id'])/reports/$($Item['sourceReportId'])/Export?downloadType=$BackupDownloadType" -OutFile $partialPath
        $contentType = [string]($response.Headers['Content-Type'] | Select-Object -First 1)
        if (($contentType -split ';')[0].Trim() -notin @('application/zip', 'application/octet-stream')) {
            throw "Respons export '$($Item['name'])' bukan file PBIX: $contentType"
        }
        $info = Get-BackupFileInfo -Path $partialPath
        if ($response.Headers.ContainsKey('Content-Length')) {
            $expectedLength = 0L
            if (-not [long]::TryParse([string]($response.Headers['Content-Length'] | Select-Object -First 1), [ref]$expectedLength) -or
                $expectedLength -ne $info['sizeBytes']) {
                throw "Ukuran download backup '$($Item['name'])' tidak sesuai Content-Length."
            }
        }
        [IO.File]::Move($partialPath, $path)
        return @{
            reportId = $Item['sourceReportId']
            name = $Item['name']
            datasetId = $Item['datasetId']
            downloadType = $BackupDownloadType
            path = $path
            sizeBytes = $info['sizeBytes']
            sha256 = $info['sha256']
            createdAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        }
    } finally {
        if (Test-Path -LiteralPath $partialPath) {
            Remove-Item -LiteralPath $partialPath
        }
    }
}

function Assert-ReportBinding {
    param(
        [System.Collections.IDictionary]$Report,
        [string]$ExpectedId,
        [string]$ExpectedName,
        [string]$ExpectedDataset
    )
    if ($Report['id'] -ne $ExpectedId -or $Report['name'] -cne $ExpectedName -or $Report['datasetId'] -ne $ExpectedDataset) {
        throw "Verifikasi report '$ExpectedName' gagal: ID, nama, atau datasetId berbeda. Cek state dan report tujuan; jangan clone ulang otomatis."
    }
}

function Get-ModelSourceSnapshot {
    param([string]$WorkspaceId, [string]$ModelId)
    $sources = Invoke-PowerBIApi -Method GET -Path "groups/$WorkspaceId/datasets/$ModelId/datasources"
    $parameters = Invoke-PowerBIApi -Method GET -Path "groups/$WorkspaceId/datasets/$ModelId/parameters"
    if ($sources['value'] -isnot [array] -or $parameters['value'] -isnot [array]) {
        throw 'Respons datasources/parameters model tidak valid: value harus array.'
    }
    $sourceKeys = @(
        foreach ($dataSource in $sources['value']) {
            if ($dataSource -isnot [System.Collections.IDictionary] -or
                [string]::IsNullOrWhiteSpace($dataSource['datasourceType']) -or
                $dataSource['connectionDetails'] -isnot [System.Collections.IDictionary]) {
                throw 'Referensi data source model tidak lengkap; migrasi tidak dilanjutkan.'
            }
            $details = [ordered]@{}
            foreach ($key in $dataSource['connectionDetails'].Keys | Sort-Object -CaseSensitive) {
                if ($null -ne $dataSource['connectionDetails'][$key] -and $dataSource['connectionDetails'][$key] -isnot [string]) {
                    throw 'Format connectionDetails data source tidak didukung.'
                }
                $details[$key] = $dataSource['connectionDetails'][$key]
            }
            [ordered]@{ datasourceType = $dataSource['datasourceType']; connectionDetails = $details } |
                ConvertTo-Json -Depth 20 -Compress
        }
    )
    $parameterKeys = @(
        foreach ($parameter in $parameters['value']) {
            if ($parameter -isnot [System.Collections.IDictionary] -or
                [string]::IsNullOrWhiteSpace($parameter['name']) -or
                [string]::IsNullOrWhiteSpace($parameter['type']) -or -not $parameter.ContainsKey('currentValue')) {
                throw 'Referensi parameter model tidak lengkap; migrasi tidak dilanjutkan.'
            }
            [ordered]@{
                name = $parameter['name']; type = $parameter['type']
                currentValue = $parameter['currentValue']; isRequired = $parameter['isRequired']
            } | ConvertTo-Json -Depth 20 -Compress
        }
    )
    $canonical = [ordered]@{
        sources = @($sourceKeys | Sort-Object -CaseSensitive)
        parameters = @($parameterKeys | Sort-Object -CaseSensitive)
    } | ConvertTo-Json -Depth 20 -Compress
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        # Persist only a fingerprint; parameter values may contain sensitive data.
        $signature = [BitConverter]::ToString($sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical))).Replace('-', '')
    } finally { $sha256.Dispose() }
    return @{ signature = $signature; sourceCount = $sourceKeys.Count }
}

function Assert-ModelSources {
    param([System.Collections.IDictionary]$Model)
    $targetModel = Invoke-PowerBIApi -Method GET -Path "groups/$($target['id'])/datasets/$($Model['targetDatasetId'])"
    if ($targetModel['id'] -ne $Model['targetDatasetId'] -or $targetModel['name'] -cne $Model['name']) {
        throw "Model tujuan '$($Model['name'])' tidak cocok dengan state."
    }
    $snapshot = Get-ModelSourceSnapshot -WorkspaceId $target['id'] -ModelId $Model['targetDatasetId']
    if ($snapshot['signature'] -cne $Model['sourceSignature']) {
        throw "Referensi sources/parameter model '$($Model['name'])' berbeda. Periksa koneksi; sumber tidak dihapus."
    }
}

function Get-ModelBackupSignature {
    param([System.Collections.IDictionary]$Backup)
    if ((Get-Item -LiteralPath $Backup['path']).Length -ge 1GB) {
        throw 'Import model PBIX >= 1 GB memerlukan jalur temporary upload terpisah; sumber tidak diubah.'
    }
    $archive = [IO.Compression.ZipFile]::OpenRead($Backup['path'])
    try {
        $dataModel = $archive.GetEntry('DataModel')
        if ($null -eq $dataModel -or $dataModel.Length -eq 0) {
            throw "Backup '$($Backup['name'])' tidak memiliki DataModel. LiveConnect/Direct Lake tidak didukung migrasi model ini."
        }
        $stream = $dataModel.Open()
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try {
            return [BitConverter]::ToString($sha256.ComputeHash($stream)).Replace('-', '')
        } finally { $sha256.Dispose(); $stream.Dispose() }
    } finally { $archive.Dispose() }
}

function Complete-ModelImport {
    param([string]$ModelId, [string]$BackupReportId)
    $model = $state['models'][$ModelId]
    if ($model['status'] -eq 'Planned') {
        $backup = $state['backups'][$BackupReportId]
        Request-ActivityConfirmation -Activity 'ImportModel' -Details "Import model '$($model['name'])' [$ModelId] dari backup '$($backup['path'])' ke '$($target['name'])' [$($target['id'])]. Tidak menimpa model yang sudah ada."
        $backupItem = @($plan | Where-Object { $_['sourceReportId'] -eq $BackupReportId })[0]
        Assert-LocalBackup -Backup $backup -Item $backupItem
        $model['status'] = 'ImportRequested'
        Save-MigrationState
        $displayName = [uri]::EscapeDataString($model['name'] + '.pbix')
        $created = Invoke-PowerBIApi -Method POST -Path "groups/$($target['id'])/imports?datasetDisplayName=$displayName&nameConflict=Abort&skipReport=true" -Form @{
            file = Get-Item -LiteralPath $backup['path']
        } -AllowAccepted
        $importId = [guid]::Empty
        if (-not [guid]::TryParse([string]$created['id'], [ref]$importId) -or $importId -eq [guid]::Empty) {
            throw "Import '$($model['name'])' tidak memiliki ID valid; jangan ulang POST."
        }
        $model['importId'] = $importId.ToString()
        $model['status'] = 'Importing'
        Save-MigrationState
    }
    if ($model['status'] -eq 'Importing') {
        Request-ActivityConfirmation -Activity 'PollImport' -Details "Pantau import '$($model['name'])' [$($model['importId'])] di workspace tujuan [$($target['id'])]. Hanya GET; tidak membuat import baru."
        for ($poll = 0; $poll -lt 180; $poll++) {
            $operation = Invoke-PowerBIApi -Method GET -Path "groups/$($target['id'])/imports/$($model['importId'])"
            if ($operation['id'] -ne $model['importId']) { throw 'ID operasi import berbeda dari state.' }
            if ($operation['importState'] -eq 'Failed') {
                $model['status'] = 'ImportFailed'
                Save-MigrationState
                throw "Import model '$($model['name'])' gagal. Periksa operasi import yang tercatat; POST tidak diulang."
            }
            if ($operation['importState'] -eq 'Succeeded') {
                if ($operation['datasets'] -isnot [array] -or $operation['datasets'].Count -ne 1 -or
                    $operation['datasets'][0]['name'] -cne $model['name'] -or
                    $operation['reports'] -isnot [array] -or $operation['reports'].Count -ne 0) {
                    throw 'Import model tidak mengembalikan tepat satu model tanpa report.'
                }
                $targetId = [guid]::Empty
                if (-not [guid]::TryParse([string]$operation['datasets'][0]['id'], [ref]$targetId) -or
                    $targetId -eq [guid]::Empty -or $targetId.ToString() -eq $ModelId) {
                    throw 'ID model tujuan tidak valid atau sama dengan model asal.'
                }
                $model['targetDatasetId'] = $targetId.ToString()
                $model['status'] = 'Imported'
                Save-MigrationState
                break
            }
            if ($operation['importState'] -notin @('Publishing', 'NotStarted')) { throw 'Status import tidak dikenal.' }
            if ($poll -lt 179) { Start-Sleep -Seconds 10 }
        }
        if ($model['status'] -eq 'Importing') { throw 'Import masih berjalan. Jalankan ulang dengan state yang sama untuk polling, bukan POST baru.' }
    }
    Request-ActivityConfirmation -Activity 'VerifyModel' -Details "Periksa ID/nama dan referensi sumber/parameter model '$($model['name'])' [$($model['targetDatasetId'])] di tujuan [$($target['id'])], lalu catat hasil ke state."
    Assert-ModelSources -Model $model
    $model['status'] = 'SourcesVerified'
    Save-MigrationState
}

function Confirm-ModelRefresh {
    param([System.Collections.IDictionary]$Model)
    if ($Model['sourceCount'] -eq 0) { return }
    if (-not $Model.ContainsKey('refreshStatus') -or $Model['refreshStatus'] -eq 'Completed') {
        Request-ActivityConfirmation -Activity 'RefreshModel' -Details "Refresh nyata model '$($Model['name'])' [$($Model['targetDatasetId'])] di tujuan [$($target['id'])]. Membaca sumber eksternal dan memakai resource capacity; report source belum dihapus."
        Assert-ModelSources -Model $Model
        $Model['refreshStatus'] = 'Requested'
        $Model.Remove('refreshId')
        Save-MigrationState
        $path = "groups/$($target['id'])/datasets/$($Model['targetDatasetId'])/refreshes"
        $accepted = Invoke-PowerBIApi -Method POST -Path $path -Body @{ notifyOption = 'NoNotification' } -AllowAccepted -RawResponse
        $location = [string]($accepted.Headers['Location'] | Select-Object -First 1)
        $refreshId = [guid]::Empty
        if (-not [string]::IsNullOrWhiteSpace($location)) {
            $locationUri = $null
            $expectedPath = ([uri]"$apiRoot/$path/").AbsolutePath
            if (-not [uri]::TryCreate($location, [UriKind]::Absolute, [ref]$locationUri) -or
                $locationUri.Scheme -ne 'https' -or -not $locationUri.IsDefaultPort -or
                $locationUri.UserInfo -ne '' -or $locationUri.Query -ne '' -or $locationUri.Fragment -ne '' -or
                ($locationUri.Host -ne 'api.powerbi.com' -and $locationUri.Host -notmatch '^wabi-[a-z0-9-]+\.analysis\.windows\.net$') -or
                -not $locationUri.AbsolutePath.StartsWith($expectedPath, [StringComparison]::OrdinalIgnoreCase) -or
                -not [guid]::TryParse($locationUri.AbsolutePath.Substring($expectedPath.Length), [ref]$refreshId)) {
                throw 'Refresh diterima tanpa Location/ID yang valid. Periksa operasi target; jangan ulang POST.'
            }
        }
        $requestId = [string]($accepted.Headers['x-ms-request-id'] | Select-Object -First 1)
        $requestGuid = [guid]::Empty
        if (-not [string]::IsNullOrWhiteSpace($requestId)) {
            if (-not [guid]::TryParse($requestId, [ref]$requestGuid) -or $requestGuid -eq [guid]::Empty -or
                ($refreshId -ne [guid]::Empty -and $refreshId -ne $requestGuid)) {
                throw 'ID refresh Location dan x-ms-request-id tidak valid atau berbeda. Periksa operasi target; jangan ulang POST.'
            }
            $refreshId = $requestGuid
        }
        if ($refreshId -eq [guid]::Empty) {
            throw 'Refresh diterima tanpa Location/ID yang valid. Periksa operasi target; jangan ulang POST.'
        }
        $Model['refreshId'] = $refreshId.ToString()
        $Model['refreshStatus'] = 'Running'
        Save-MigrationState
    }
    if ($Model['refreshStatus'] -ne 'Running') {
        throw "Refresh '$($Model['name'])' berstatus $($Model['refreshStatus']). Konfigurasi credentials/gateway di Service dan tinjau state sebelum mencoba ulang."
    }
    Request-ActivityConfirmation -Activity 'PollRefresh' -Details "Pantau refresh model '$($Model['name'])' [$($Model['refreshId'])] sampai Completed/gagal. Tidak mengulang POST refresh."
    for ($poll = 0; $poll -lt 180; $poll++) {
        $refresh = Invoke-PowerBIApi -Method GET -Path "groups/$($target['id'])/datasets/$($Model['targetDatasetId'])/refreshes/$($Model['refreshId'])" -AllowAccepted
        if ($refresh['status'] -eq 'Completed') {
            $Model['refreshStatus'] = 'Completed'
            Save-MigrationState
            return
        }
        if ($refresh['status'] -in @('Failed', 'Cancelled', 'Disabled')) {
            $Model['refreshStatus'] = $refresh['status']
            Save-MigrationState
            throw "Refresh model '$($Model['name'])' gagal. Konfigurasi credentials/koneksi/gateway di Power BI Service. Report asal tidak dihapus."
        }
        if ($refresh['status'] -notin @('Unknown', 'NotStarted', 'InProgress')) { throw 'Status refresh tidak dikenal.' }
        if ($poll -lt 179) { Start-Sleep -Seconds 10 }
    }
    throw 'Refresh masih berjalan; lanjutkan polling melalui state yang sama. Penghapusan sumber tidak dijalankan.'
}

function Assert-SourceDeletionSafety {
    param([System.Collections.IDictionary]$Item, [System.Collections.IDictionary]$Record)
    $targetReportId = [guid]::Empty
    if (-not [guid]::TryParse([string]$Record['targetReportId'], [ref]$targetReportId) -or
        $targetReportId -eq [guid]::Empty -or $Record['targetReportId'] -eq $Item['sourceReportId']) {
        throw 'ID report tujuan tidak valid untuk penghapusan. Report asal tidak dihapus.'
    }
    Assert-LocalBackup -Backup $state['backups'][$Item['sourceReportId']] -Item $Item
    foreach ($workspace in @($source, $target)) {
        $current = Invoke-PowerBIApi -Method GET -Path "groups/$($workspace['id'])"
        if ($current['id'] -ne $workspace['id'] -or $current['capacityId'] -ne $state['capacityId'] -or
            $current['isOnDedicatedCapacity'] -ne $true -or $current['isReadOnly'] -ne $false) {
            throw 'Workspace, capacity atau akses berubah sebelum DELETE. Report asal tidak dihapus.'
        }
    }
    $expectedModel = if ($IncludeSemanticModels) { $Record['targetDatasetId'] } else { $Record['datasetId'] }
    $currentTarget = Invoke-PowerBIApi -Method GET -Path "groups/$($target['id'])/reports/$($Record['targetReportId'])"
    Assert-ReportBinding -Report $currentTarget -ExpectedId $Record['targetReportId'] -ExpectedName $Record['name'] -ExpectedDataset $expectedModel
    if ($IncludeSemanticModels) {
        $model = $state['models'][$Item['datasetId']]
        Assert-ModelSources -Model $model
        if ($Item['sourcePresent'] -and $model['sourceCount'] -gt 0 -and $model['refreshStatus'] -ne 'Completed') {
            throw 'Refresh model tujuan belum Completed. Report asal tidak dihapus.'
        }
    }
    if ($Item['sourcePresent']) {
        $currentSource = Invoke-PowerBIApi -Method GET -Path "groups/$($source['id'])/reports/$($Item['sourceReportId'])"
        Assert-ReportBinding -Report $currentSource -ExpectedId $Item['sourceReportId'] -ExpectedName $Item['name'] -ExpectedDataset $Item['datasetId']
    }
}

$resolvedStatePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($StatePath)
$resolvedBackupDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($BackupDirectory)
$lock = $null
try {
    if ($WhatIf) {
        $Apply = $false
        Write-Host 'WHATIF: hanya login dan pemeriksaan baca/preview; tidak ada backup, state, lock, POST atau DELETE.'
    }
    if ($IncludeSemanticModels -and $BackupDownloadType -ne 'IncludeModel') {
        throw '-IncludeSemanticModels membutuhkan -BackupDownloadType IncludeModel.'
    }
    if ($Apply) {
        Request-ActivityConfirmation -Activity 'PrepareLocal' -Details "Siapkan folder state dan lock eksklusif '$resolvedStatePath.lock'. Backup: '$resolvedBackupDirectory'. Mode: $Mode; sumber '$SourceWorkspace'; tujuan '$TargetWorkspace'."
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($resolvedStatePath))
        # Keep this file so concurrent processes always lock the same file.
        $lock = [IO.File]::Open("$resolvedStatePath.lock", [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    }
    foreach ($commandName in @('Connect-PowerBIServiceAccount', 'Get-PowerBIAccessToken')) {
        $command = Get-Command $commandName -ErrorAction SilentlyContinue
        if ($null -eq $command -or
            ($null -ne $command.Module -and $command.Module.Version -lt [version]'1.3.84')) {
            throw 'Pasang/update modul autentikasi: Install-Module MicrosoftPowerBIMgmt.Profile -MinimumVersion 1.3.84 -Scope CurrentUser -Force. Kemudian gunakan sesi PowerShell baru.'
        }
    }
    Request-ActivityConfirmation -Activity 'Login' -Details "Buka login interaktif Power BI cloud Public. Pilih akun organisasi yang memiliki akses ke '$SourceWorkspace' dan '$TargetWorkspace'."
    Write-Host 'Login interaktif Power BI: pilih akun pengguna yang memiliki akses ke kedua workspace.'
    $null = Connect-PowerBIServiceAccount -Environment Public -ErrorAction Stop
    Request-ActivityConfirmation -Activity 'Discovery' -Details "Baca workspace/capacity, state '$resolvedStatePath', report dan metadata model bila dipilih. Tidak membuat/menghapus item layanan."
    $workspaces = @(Get-PowerBIWorkspaces)
    $source = Resolve-Workspace -Workspaces $workspaces -Identifier $SourceWorkspace
    $target = Resolve-Workspace -Workspaces $workspaces -Identifier $TargetWorkspace
    if ($source['id'] -eq $target['id']) {
        throw 'Workspace asal dan tujuan harus berbeda.'
    }
    foreach ($workspace in @($source, $target)) {
        $capacity = [guid]::Empty
        if ($workspace['isOnDedicatedCapacity'] -ne $true -or
            -not [guid]::TryParse([string]$workspace['capacityId'], [ref]$capacity) -or $capacity -eq [guid]::Empty) {
            throw "Workspace '$($workspace['name'])' belum memiliki capacityId dedicated yang valid."
        }
        if ($workspace['isReadOnly'] -ne $false) {
            throw "Workspace '$($workspace['name'])' tidak memiliki akses tulis untuk akun ini."
        }
    }
    if ($source['capacityId'] -ne $target['capacityId']) {
        throw 'capacityId workspace asal dan tujuan berbeda. Script ini tidak mengubah penempatan capacity.'
    }

    $state = @{
        schemaVersion = 1
        sourceWorkspaceId = $source['id']
        targetWorkspaceId = $target['id']
        capacityId = $source['capacityId']
        reports = @{}
        backups = @{}
    }
    if (Test-Path -LiteralPath $resolvedStatePath) {
        $state = Get-Content -LiteralPath $resolvedStatePath -Raw | ConvertFrom-Json -AsHashtable
        if ($state['schemaVersion'] -ne 1 -or $state['sourceWorkspaceId'] -ne $source['id'] -or
            $state['targetWorkspaceId'] -ne $target['id'] -or $state['capacityId'] -ne $source['capacityId'] -or
            $state['reports'] -isnot [System.Collections.IDictionary]) {
            throw 'State tidak cocok dengan pasangan workspace/capacity atau formatnya tidak valid. Gunakan StatePath khusus untuk pasangan ini.'
        }
    }
    if (-not $state.ContainsKey('backups')) {
        $state['backups'] = @{}
    }
    if ($state['backups'] -isnot [System.Collections.IDictionary]) {
        throw 'Format backups dalam state tidak valid.'
    }
    if (-not $state.ContainsKey('models')) { $state['models'] = @{} }
    if ($state['models'] -isnot [System.Collections.IDictionary]) { throw 'Format models dalam state tidak valid.' }

    $sourceResponse = Invoke-PowerBIApi -Method GET -Path "groups/$($source['id'])/reports"
    $targetResponse = Invoke-PowerBIApi -Method GET -Path "groups/$($target['id'])/reports"
    $reports = @(Get-PowerBICollection -Response $sourceResponse -Label 'report')
    $targetReports = @(Get-PowerBICollection -Response $targetResponse -Label 'report')
    $liveSourceIds = @($reports | ForEach-Object { $_['id'] })
    if ($Mode -eq 'Move') {
        foreach ($entry in $state['reports'].GetEnumerator()) {
            if ($entry.Value['status'] -in @('DeleteRequested', 'SourceDeleted') -and $entry.Key -notin $liveSourceIds) {
                $reports += @{
                    id = $entry.Key
                    name = $entry.Value['name']
                    datasetId = $entry.Value['datasetId']
                }
            }
        }
    }
    if ($null -ne $ReportIds -and $ReportIds.Count -gt 0) {
        $availableIds = @($reports | ForEach-Object { $_['id'] })
        foreach ($requested in $ReportIds) {
            if ($requested -eq [guid]::Empty -or $requested.ToString() -notin $availableIds) {
                throw "Report ID '$requested' tidak ditemukan di workspace asal."
            }
        }
        $selectedIds = @($ReportIds | ForEach-Object { $_.ToString() })
        $reports = @($reports | Where-Object { $_['id'] -in $selectedIds })
    }
    if ($reports.Count -eq 0) {
        throw 'Tidak ada report untuk dimigrasikan.'
    }
    $duplicateNames = @($reports | Group-Object { $_['name'] } | Where-Object Count -gt 1)
    if ($duplicateNames.Count -gt 0) {
        throw 'Ada report asal dengan nama sama. Pilih satu per nama menggunakan -ReportIds.'
    }

    $plan = @(
        foreach ($report in $reports) {
            $reportId = [string]$report['id']
            if ([string]::IsNullOrWhiteSpace($report['name']) -or
                [string]::IsNullOrWhiteSpace($report['datasetId']) -or
                ($report.ContainsKey('reportType') -and $report['reportType'] -ne 'PowerBIReport')) {
                throw "Report '$($report['name'])' bukan Power BI report dengan datasetId. RDL/paginated dan report tanpa datasetId tidak didukung script ini."
            }
            $existing = @($targetReports | Where-Object { $_['name'] -eq $report['name'] })
            $action = 'Clone'
            if ($state['reports'].ContainsKey($reportId)) {
                $record = $state['reports'][$reportId]
                $hasTargetModel = $record.ContainsKey('targetDatasetId') -and $record['targetDatasetId'] -ne $record['datasetId']
                if ([bool]$hasTargetModel -ne [bool]$IncludeSemanticModels) {
                    throw 'Cakupan model berbeda dari state report. Gunakan StatePath baru atau lanjutkan opsi IncludeSemanticModels yang sama; script tidak rebind hasil lama otomatis.'
                }
                if ($record['name'] -cne $report['name'] -or $record['datasetId'] -ne $report['datasetId']) {
                    throw "Report asal '$($report['name'])' berubah sejak pencatatan state. Tinjau manual."
                }
                if ($record['status'] -eq 'CloneRequested') {
                    throw "Hasil clone '$($report['name'])' belum pasti. Cek workspace tujuan dan state sebelum melanjutkan; POST tidak diulang."
                }
                if ($record['status'] -notin @('Created', 'Verified', 'DeleteRequested', 'SourceDeleted')) {
                    throw "Status state '$($record['status'])' tidak dikenal."
                }
                if ($record['status'] -in @('DeleteRequested', 'SourceDeleted') -and $Mode -ne 'Move') {
                    throw "Report '$($report['name'])' memiliki proses Move di state. Gunakan -Mode Move untuk melanjutkan; Copy tidak menghapus sumber."
                }
                if ($record['status'] -eq 'SourceDeleted' -and $reportId -in $liveSourceIds) {
                    throw "Report asal '$($report['name'])' muncul lagi setelah SourceDeleted. Tinjau manual; sumber tidak dihapus ulang."
                }
                if ($existing.Count -ne 1 -or $existing[0]['id'] -ne $record['targetReportId']) {
                    throw "Report tujuan '$($report['name'])' hilang atau konflik dengan state. Tinjau manual."
                }
                $expectedModel = if ($hasTargetModel) { $record['targetDatasetId'] } else { $record['datasetId'] }
                Assert-ReportBinding -Report $existing[0] -ExpectedId $record['targetReportId'] -ExpectedName $record['name'] -ExpectedDataset $expectedModel
                $action = 'VerifyExisting'
            } elseif ($existing.Count -gt 0) {
                throw "Nama '$($report['name'])' sudah ada di tujuan tetapi tidak tercatat di state. Script tidak menimpa atau menganggapnya hasil migrasi."
            }
            @{
                sourceReportId = $reportId
                name = [string]$report['name']
                datasetId = [string]$report['datasetId']
                action = $action
                sourcePresent = ($reportId -in $liveSourceIds)
                sourceAction = if ($Mode -eq 'Copy') { 'Keep' } elseif ($reportId -in $liveSourceIds) { 'Delete' } else { 'ConfirmDeleted' }
            }
        }
    )
    $modelIds = @($plan | ForEach-Object { $_['datasetId'] } | Select-Object -Unique)
    if ($IncludeSemanticModels) {
        $modelResponse = Invoke-PowerBIApi -Method GET -Path "groups/$($target['id'])/datasets"
        $targetModels = @(Get-PowerBICollection -Response $modelResponse -Label 'model')
        foreach ($modelId in $modelIds) {
            $sourceModel = Invoke-PowerBIApi -Method GET -Path "groups/$($source['id'])/datasets/$modelId"
            if ($sourceModel['id'] -ne $modelId -or [string]::IsNullOrWhiteSpace($sourceModel['name']) -or $sourceModel['isRefreshable'] -ne $true) {
                throw 'Migrasi model ini hanya mendukung model Import refreshable di workspace source. DirectQuery/Direct Lake/model eksternal memerlukan jalur terpisah.'
            }
            $snapshot = Get-ModelSourceSnapshot -WorkspaceId $source['id'] -ModelId $modelId
            if ($state['models'].ContainsKey($modelId)) {
                $model = $state['models'][$modelId]
                if ($model['name'] -cne $sourceModel['name'] -or $model['sourceSignature'] -cne $snapshot['signature']) {
                    throw 'Nama atau referensi sources/parameter model asal berubah sejak state dibuat.'
                }
                if ($model['status'] -notin @('Planned', 'Importing', 'Imported', 'SourcesVerified')) {
                    throw "Status model $($model['status']) membutuhkan tinjauan manual; jangan ulang POST import."
                }
            } else {
                $model = @{
                    name = $sourceModel['name']; sourceSignature = $snapshot['signature']
                    sourceCount = $snapshot['sourceCount']; status = 'Planned'; targetDatasetId = $null
                }
                $state['models'][$modelId] = $model
            }
            $conflicts = @($targetModels | Where-Object { $_['name'] -eq $model['name'] })
            if ($conflicts.Count -gt 0 -and ($model['status'] -ne 'Importing') -and
                ($conflicts.Count -ne 1 -or $conflicts[0]['id'] -ne $model['targetDatasetId'])) {
                throw "Nama model '$($model['name'])' konflik di tujuan; model tidak ditimpa/adopsi otomatis."
            }
        }
        if (@($modelIds | ForEach-Object { [pscustomobject]$state['models'][$_] } | Group-Object name | Where-Object Count -gt 1).Count -gt 0) {
            throw 'Model asal terpilih memiliki nama yang sama; pilih laporan dengan model bernama unik.'
        }
    }
    Write-Host "Asal: $($source['name']) [$($source['id'])]"
    Write-Host "Tujuan: $($target['name']) [$($target['id'])]"
    Write-Host "Capacity sama: $($source['capacityId'])"
    Write-Host "Mode: $Mode"
    Write-Host "Backup lokal: $resolvedBackupDirectory [$BackupDownloadType]"
    if ($BackupDownloadType -eq 'LiveConnect') {
        Write-Warning 'Backup LiveConnect tidak berisi data/model offline. Pemulihan masih membutuhkan semantic model online dan akses pengguna.'
    }
    if ($IncludeSemanticModels) {
        Write-Warning 'Semantic model terkait akan disalin dan report tujuan terikat ke model baru. Sumber data fisik, credentials, gateway binding dan model asal tidak dihapus/dipindahkan. Move mensyaratkan refresh sumber target berhasil.'
    } else {
        Write-Warning 'Semantic model tetap di lokasi asal. Jangan hapus workspace/model asal; akses pengguna ke model tetap diperlukan.'
    }
    if ($Mode -eq 'Move') {
        Write-Warning 'MOVE akan menghapus report asal setelah semua tujuan lolos verifikasi API. URL/sharing/app lama dapat terputus; verifikasi API bukan uji visual/RLS.'
    }
    $plan | ForEach-Object { [pscustomobject]$_ } | Format-Table name, sourceReportId, datasetId, action, sourceAction | Out-Host
    if (-not $Apply) {
        Write-Host 'PREVIEW saja: tidak ada report dibuat atau dihapus. Tambahkan -Apply untuk menjalankan.'
        $plan | ForEach-Object { [pscustomobject]$_ }
        return
    }
    Request-ActivityConfirmation -Activity 'ExecutePlan' -Details "Jalankan rencana $Mode untuk $($plan.Count) report dari '$($source['name'])' [$($source['id'])] ke '$($target['name'])' [$($target['id'])], capacity [$($source['capacityId'])]. IncludeSemanticModels=$([bool]$IncludeSemanticModels). Buat backup/manifest dan catat state '$resolvedStatePath'. Setiap aktivitas berikutnya tetap meminta persetujuan."

    $runDirectory = Join-Path $resolvedBackupDirectory (
        '{0}_to_{1}\{2}_{3}' -f $source['id'], $target['id'],
        [DateTimeOffset]::UtcNow.ToString('yyyyMMdd_HHmmss_fff'), [guid]::NewGuid().ToString('N')
    )
    $null = [IO.Directory]::CreateDirectory($runDirectory)
    $manifest = @{
        schemaVersion = 1
        sourceWorkspaceId = $source['id']
        targetWorkspaceId = $target['id']
        capacityId = $source['capacityId']
        reports = @{}
    }
    foreach ($item in $plan) {
        $reportId = $item['sourceReportId']
        $backupAction = if ($item['sourcePresent']) { 'Export PBIX baru' } else { 'Periksa backup lama untuk resume; sumber sudah tidak ada' }
        Request-ActivityConfirmation -Activity 'BackupReport' -Details "$backupAction untuk '$($item['name'])' [$reportId], workspace source [$($source['id'])], jenis $BackupDownloadType; manifest run '$runDirectory'. Catat backup ke state; belum clone/DELETE."
        if ($item['sourcePresent']) {
            $backup = Save-ReportBackup -Item $item -Directory $runDirectory
        } else {
            $backup = $state['backups'][$reportId]
            Assert-LocalBackup -Backup $backup -Item $item
        }
        $manifest['reports'][$reportId] = $backup
        Save-JsonFile -Data $manifest -Path (Join-Path $runDirectory 'backup-manifest.json')
        $state['backups'][$reportId] = $backup
        Save-MigrationState
        Write-Host "Backup verified: $($item['name']) -> $($backup['path'])"
    }
    Request-ActivityConfirmation -Activity 'VerifyBackups' -Details "Periksa ulang seluruh $($plan.Count) backup lokal sebelum perubahan layanan; jika menyertakan model, periksa snapshot DataModel dan simpan fingerprint."
    foreach ($item in $plan) {
        Assert-LocalBackup -Backup $state['backups'][$item['sourceReportId']] -Item $item
    }
    if ($IncludeSemanticModels) {
        foreach ($modelId in $modelIds) {
            $backupItem = @($plan | Where-Object { $_['datasetId'] -eq $modelId })[0]
            $signature = Get-ModelBackupSignature -Backup $state['backups'][$backupItem['sourceReportId']]
            $model = $state['models'][$modelId]
            if ($model.ContainsKey('sourceDataModelSignature') -and $model['sourceDataModelSignature'] -cne $signature) {
                throw 'Snapshot DataModel sumber berubah sejak migrasi model. Tinjau model tujuan; jangan memakai model lama untuk report yang berubah.'
            }
            $model['sourceDataModelSignature'] = $signature
        }
        Save-MigrationState
        foreach ($modelId in $modelIds) {
            $backupItem = @($plan | Where-Object { $_['datasetId'] -eq $modelId })[0]
            Complete-ModelImport -ModelId $modelId -BackupReportId $backupItem['sourceReportId']
        }
    }

    foreach ($item in $plan) {
        $reportId = $item['sourceReportId']
        if ($item['action'] -eq 'Clone') {
            Request-ActivityConfirmation -Activity 'CloneReport' -Details "Salin report '$($item['name'])' [$reportId] dari source [$($source['id'])] ke destination [$($target['id'])]. ID/URL report baru; tidak menimpa. IncludeSemanticModels=$([bool]$IncludeSemanticModels)."
            $currentSource = Invoke-PowerBIApi -Method GET -Path "groups/$($source['id'])/reports/$reportId"
            Assert-ReportBinding -Report $currentSource -ExpectedId $reportId -ExpectedName $item['name'] -ExpectedDataset $item['datasetId']
            $currentTargets = Invoke-PowerBIApi -Method GET -Path "groups/$($target['id'])/reports"
            $newConflicts = @(Get-PowerBICollection -Response $currentTargets -Label 'report' | Where-Object { $_['name'] -eq $item['name'] })
            if ($newConflicts.Count -gt 0) { throw 'Konflik report baru muncul setelah konfirmasi. Clone dibatalkan tanpa POST.' }
            Assert-LocalBackup -Backup $state['backups'][$reportId] -Item $item
            $state['reports'][$reportId] = @{
                name = $item['name']
                datasetId = $item['datasetId']
                targetReportId = $null
                status = 'CloneRequested'
                updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
            }
            if ($IncludeSemanticModels) {
                $state['reports'][$reportId]['targetDatasetId'] = $state['models'][$item['datasetId']]['targetDatasetId']
            }
            Save-MigrationState
            $cloneBody = @{
                name = $item['name']
                targetWorkspaceId = $target['id']
            }
            if ($IncludeSemanticModels) { $cloneBody['targetModelId'] = $state['reports'][$reportId]['targetDatasetId'] }
            $created = Invoke-PowerBIApi -Method POST -Path "groups/$($source['id'])/reports/$reportId/Clone" -Body $cloneBody
            $createdId = [guid]::Empty
            if (-not [guid]::TryParse([string]$created['id'], [ref]$createdId) -or $createdId -eq [guid]::Empty) {
                throw "Clone '$($item['name'])' tidak mengembalikan ID valid. Cek tujuan; jangan ulang POST."
            }
            $state['reports'][$reportId]['targetReportId'] = $createdId.ToString()
            $state['reports'][$reportId]['status'] = 'Created'
            Save-MigrationState
        }
        $record = $state['reports'][$reportId]
        Request-ActivityConfirmation -Activity 'VerifyReport' -Details "GET dan verifikasi report '$($record['name'])' [$($record['targetReportId'])] di destination [$($target['id'])], cocokkan ID/nama/binding model, lalu catat hasil. Ini bukan uji visual/RLS."
        $verified = Invoke-PowerBIApi -Method GET -Path "groups/$($target['id'])/reports/$($record['targetReportId'])"
        $expectedModel = if ($IncludeSemanticModels) { $record['targetDatasetId'] } else { $record['datasetId'] }
        Assert-ReportBinding -Report $verified -ExpectedId $record['targetReportId'] -ExpectedName $record['name'] -ExpectedDataset $expectedModel
        if ($record['status'] -notin @('DeleteRequested', 'SourceDeleted')) {
            $record['status'] = 'Verified'
        }
        $record['webUrl'] = $verified['webUrl']
        $record['updatedAtUtc'] = [DateTimeOffset]::UtcNow.ToString('o')
        Save-MigrationState
        Write-Host "Verified: $($record['name']) [$($record['targetReportId'])]"
    }
    if ($Mode -eq 'Move') {
        Request-ActivityConfirmation -Activity 'MoveCutover' -Details "CUTOVER ke '$($target['name'])' [$($target['id'])]. Dengan menyetujui, Anda menyatakan backup/pemulihan, visual, angka, akses/RLS dan persetujuan pemilik sudah diperiksa. Verifikasi API saja tidak membuktikannya. Report source yang masih ada akan dihapus satu per satu, bukan transaksi/rollback otomatis; model dan workspace source tetap ada." -RequiredText "CUTOVER $($target['id'])"
        Request-ActivityConfirmation -Activity 'ValidateMove' -Details "Periksa ulang seluruh backup, model/koneksi tujuan dan sumber sebelum penghapusan pertama. Refresh model tujuan bila diperlukan akan meminta persetujuan terpisah."
        if ($IncludeSemanticModels) {
            foreach ($modelId in $modelIds) {
                Assert-ModelSources -Model $state['models'][$modelId]
                if (@($plan | Where-Object { $_['datasetId'] -eq $modelId -and $_['sourcePresent'] }).Count -gt 0) {
                    Confirm-ModelRefresh -Model $state['models'][$modelId]
                }
            }
        }
        # Check every source before the first deletion, not just before its own deletion.
        foreach ($item in $plan) {
            Assert-LocalBackup -Backup $state['backups'][$item['sourceReportId']] -Item $item
        }
        foreach ($item in $plan | Where-Object { $_['sourcePresent'] }) {
            $currentSource = Invoke-PowerBIApi -Method GET -Path "groups/$($source['id'])/reports/$($item['sourceReportId'])"
            Assert-ReportBinding -Report $currentSource -ExpectedId $item['sourceReportId'] -ExpectedName $item['name'] -ExpectedDataset $item['datasetId']
        }
        foreach ($item in $plan) {
            $record = $state['reports'][$item['sourceReportId']]
            $sourcePath = "groups/$($source['id'])/reports/$($item['sourceReportId'])"
            if ($item['sourcePresent']) {
                Request-ActivityConfirmation -Activity 'DeleteSource' -Details "HAPUS report '$($item['name'])' [$($item['sourceReportId'])] dari '$($source['name'])' [$($source['id'])]. Target '$($target['name'])' [$($target['id'])], report [$($record['targetReportId'])]. Backup '$($state['backups'][$item['sourceReportId']]['path'])'. ID/URL lama berhenti berlaku; tidak ada rollback otomatis. Setelah jawaban, semua pemeriksaan kritis diulang sebelum DELETE." -RequiredText "HAPUS $($item['sourceReportId']) DARI $($source['id'])"
            } else {
                Request-ActivityConfirmation -Activity 'VerifyDeletion' -Details "Resume report '$($item['name'])' [$($item['sourceReportId'])]: verifikasi target/backup dan pastikan source [$($source['id'])] memberikan HTTP 404. Tidak mengirim DELETE untuk sumber yang sudah hilang."
            }
            Assert-SourceDeletionSafety -Item $item -Record $record
            if ($record['status'] -ne 'SourceDeleted') {
                Assert-LocalBackup -Backup $state['backups'][$item['sourceReportId']] -Item $item
                $record['status'] = 'DeleteRequested'
                $record['updatedAtUtc'] = [DateTimeOffset]::UtcNow.ToString('o')
                if ($item['sourcePresent']) {
                    $record['deletionApproval'] = @{
                        approvedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
                        sourceReportId = $item['sourceReportId']
                        sourceWorkspaceId = $source['id']
                        targetWorkspaceId = $target['id']
                        targetReportId = $record['targetReportId']
                        backupSha256 = $state['backups'][$item['sourceReportId']]['sha256']
                    }
                }
                Save-MigrationState
                if ($item['sourcePresent']) {
                    Invoke-PowerBIApi -Method DELETE -Path $sourcePath
                }
            }
            $remainingSource = Invoke-PowerBIApi -Method GET -Path $sourcePath -AllowNotFound
            if ($null -ne $remainingSource) {
                throw "Penghapusan report asal '$($item['name'])' belum terkonfirmasi. Tinjau state dan jalankan ulang -Mode Move; sumber tidak dihapus ulang otomatis."
            }
            $record['status'] = 'SourceDeleted'
            $record['updatedAtUtc'] = [DateTimeOffset]::UtcNow.ToString('o')
            Save-MigrationState
            Write-Host "Moved: $($record['name']); report asal sudah tidak ditemukan melalui API."
        }
    }
    Write-Host "Selesai ($Mode): $($plan.Count) report terverifikasi melalui API. State: $resolvedStatePath"
    Write-Host "Manifest backup lokal: $(Join-Path $runDirectory 'backup-manifest.json')"
    Write-Warning 'Verifikasi API bukan pemeriksaan visual/data/RLS. Buka report sebagai pengguna tujuan sebelum cutover.'
    foreach ($item in $plan) {
        [pscustomobject]$state['reports'][$item['sourceReportId']]
    }
} finally {
    if ($null -ne $lock) {
        $lock.Dispose()
    }
}
