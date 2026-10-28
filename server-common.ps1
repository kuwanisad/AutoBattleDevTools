# server-common.ps1
# start-servers.ps1 / stop-servers.ps1 / control-server.ps1이 같이 쓰는 함수 모음.
# 직접 실행하는 스크립트가 아니다 - 각 스크립트가 맨 위에서 dot-source(. "$PSScriptRoot\server-common.ps1")한다.
#
# "하네스 모드"(-LogDir 지정)일 때 쓰는 것들이 대부분이다:
#   - 서버를 창 없이 띄우고 콘솔 출력(stdout/stderr)을 LogDir 안의 파일로 받는다.
#   - 로그 형식을 JSON 한 줄(시각 UTC 포함)로 바꾼다 - 서버 코드는 안 건드리고 설정(환경 변수)으로만.
#   - 고정 대기(Start-Sleep) 대신 로그에 "Application started"가 찍힐 때까지 기다린다.
#   - PID 파일을 DevTools가 아니라 LogDir 안에 둔다 - 손으로 띄운 서버(수동 모드)와 섞이지 않게.
#   - -HarnessAddress를 주면 서버에 HARNESS_ADDRESS/HARNESS_NAME을 넣어 테스트 하네스에 접속하게 한다.
#   - 끝날 때 결과를 LogDir 안의 JSON 파일(start-result.json / control-result.json)로 남긴다 - 하네스는
#     콘솔 문구가 아니라 이 파일로 성공/실패를 판단한다(아래 "하네스 결과 파일").
# -LogDir 없이 실행하면(수동 모드) 예전과 똑같이 동작한다.

# 실행 순서(종료는 역순). start-servers.ps1의 단계 번호도 이 순서를 따른다.
$ServerOrder = @(
    "MasterServer",
    "MatchingServer",   # 마스터 서버 직후 - 마스터가 주소를 메인 서버들에 전달
    "AccountServer",    # 로그인 서버가 계정 검증/생성에 씀 - 로그인 서버보다 먼저
    "LoginServer",      # 클라 최초 진입점 - AccountServer/MatchingServer 주소가 필요
    "DummySubServer",
    "LobbyServer",
    "GameAgent",
    "ChatServer"
)

# 하네스 모드에서 서버 프로세스에만 넣어주는 로그 설정. ASP.NET Core가 환경 변수의 "__"를
# 설정 경로(Logging:Console:FormatterName)로 읽으므로 서버 코드/appsettings 수정이 필요 없다.
# 한글은 JSON 안에서 \uXXXX로 이스케이프돼 나온다 - 콘솔 코드페이지와 무관하게 안 깨진다.
$HarnessLoggingEnvironment = [ordered]@{
    "Logging__Console__FormatterName"                  = "json"
    "Logging__Console__FormatterOptions__TimestampFormat" = "yyyy-MM-ddTHH:mm:ss.fffZ"
    "Logging__Console__FormatterOptions__UseUtcTimestamp" = "true"
}

# 서버가 다 떴다는 표시 - ASP.NET Core 호스트가 모든 시작 작업을 끝낸 뒤 찍는 줄.
$ReadyMarker = "Application started"

# ---------------------------------------------------------------------------------------------
# 하네스 결과 파일
#
# 하네스(TestHarness/HarnessDaemon)가 이 스크립트들을 부른 뒤 읽는 기계용 결과. 사람용 콘솔 문구는
# 그대로 두고, 같은 내용을 단계(Docker, BrokerInitializer, 서버)마다 한 줄씩 모았다가 끝날 때 쓴다.
#   { "ok": false, "action": "start", "finishedUtc": "...",
#     "results": [ { "name": "LoginServer", "status": "ready", "pid": 1234, "detail": "",
#                    "log": "...\LoginServer.log", "errLog": "...\LoginServer.err.log" }, ... ] }
# status: ready(떴음/끝남) | failed | skipped(건너뜀) | killed | not-running
# detail은 영문 짧은 코드(exited, timeout, missing-dll, already-running, aborted ...) - Windows
# PowerShell 5.1이 이 스크립트를 ANSI로 읽기 때문에, 한글을 넣으면 하네스 쪽에서 깨져 보인다.
# 파일은 UTF-8(BOM 없음)로 쓴다 - Set-Content는 5.1에서 ANSI로 써서 쓰지 않는다.
# ---------------------------------------------------------------------------------------------
$script:HarnessResults = New-Object System.Collections.ArrayList

function Add-HarnessResult {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Status,
        [int]$ProcessId = 0,
        [string]$Detail = "",
        [string]$LogPath = "",
        [string]$ErrPath = ""
    )

    [void]$script:HarnessResults.Add([ordered]@{
        name   = $Name
        status = $Status
        pid    = $ProcessId
        detail = $Detail
        log    = $LogPath
        errLog = $ErrPath
    })
}

function Save-HarnessResult {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][bool]$Ok,
        [Parameter(Mandatory)][string]$Action
    )

    $document = [ordered]@{
        ok          = $Ok
        action      = $Action
        finishedUtc = (Get-Date).ToUniversalTime().ToString("o")
        results     = @($script:HarnessResults)
    }
    $json = ConvertTo-Json -InputObject $document -Depth 5
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-PidFilePath {
    param([string]$DevTools, [string]$LogDir)

    if ($LogDir) { return Join-Path $LogDir "server-pids.json" }
    return Join-Path $DevTools "server-pids.json"
}

function Read-PidFile {
    param([string]$Path)

    $map = @{}
    if (Test-Path $Path) {
        $obj = Get-Content $Path -Raw | ConvertFrom-Json
        foreach ($entry in $obj.PSObject.Properties) { $map[$entry.Name] = $entry.Value }
    }
    return $map
}

function Save-PidFile {
    param([hashtable]$Map, [string]$Path)

    $Map | ConvertTo-Json | Set-Content $Path
}

# LogDir를 만들고 절대 경로로 돌려준다 - Start-Process의 작업 폴더가 서버 프로젝트 폴더라
# 상대 경로를 그대로 넘기면 엉뚱한 곳에 로그가 생긴다.
function Resolve-LogDir {
    param([string]$LogDir)

    return (New-Item -ItemType Directory -Force -Path $LogDir).FullName
}

# 같은 서버를 재시작(control-server.ps1 -Action Restart)하면 이전 로그를 덮어쓰지 않도록
# Name.log → Name.2.log → Name.3.log ... 순으로 비어있는 이름을 고른다.
function Get-FreeLogBaseName {
    param([string]$LogDir, [string]$Name)

    if (-not (Test-Path (Join-Path $LogDir "$Name.log"))) { return $Name }

    $n = 2
    while (Test-Path (Join-Path $LogDir "$Name.$n.log")) { $n++ }
    return "$Name.$n"
}

# 하네스 모드로 프로세스 하나를 띄운다. stdout → <base>.log, stderr → <base>.err.log
# (PowerShell은 두 출력을 같은 파일로 받을 수 없어서 나눈다).
# 반환: @{ Process = ...; LogPath = ...; ErrPath = ... }
function Start-HarnessProcess {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string[]]$DotnetArguments,
        [Parameter(Mandatory)][string]$LogDir,
        # 로그 설정 말고 이 프로세스에만 더 넣을 환경 변수(예: HARNESS_ADDRESS). 값이 빈 항목은 무시.
        [hashtable]$ExtraEnvironment = @{},
        [switch]$Wait
    )

    $base = Get-FreeLogBaseName -LogDir $LogDir -Name $Name
    $logPath = Join-Path $LogDir "$base.log"
    $errPath = Join-Path $LogDir "$base.err.log"

    $startArgs = @{
        FilePath               = "dotnet"
        ArgumentList           = $DotnetArguments
        WorkingDirectory       = $WorkingDirectory
        RedirectStandardOutput = $logPath
        RedirectStandardError  = $errPath
        PassThru               = $true
        Wait                   = [bool]$Wait
    }
    # Windows에선 숨은 창으로 띄운다(창이 안 뜨고, 이 스크립트를 부른 콘솔과도 분리돼서
    # 거기서 Ctrl+C를 눌러도 서버가 같이 죽지 않는다). 다른 OS엔 창 개념이 없어 생략.
    if ($PSVersionTable.PSEdition -eq "Desktop" -or $IsWindows) {
        $startArgs["WindowStyle"] = "Hidden"
    }

    # 환경 변수는 띄우는 순간에만 넣었다가 바로 되돌린다 - 이 스크립트를 대화형 콘솔에서
    # 실행했을 때 그 콘솔에 설정이 남아, 나중에 수동 모드로 띄운 서버까지 JSON으로 출력하거나
    # 하네스에 접속하려 드는 일을 막기 위해.
    $environment = [ordered]@{}
    foreach ($key in $HarnessLoggingEnvironment.Keys) { $environment[$key] = $HarnessLoggingEnvironment[$key] }
    foreach ($key in $ExtraEnvironment.Keys) {
        if ($ExtraEnvironment[$key]) { $environment[$key] = $ExtraEnvironment[$key] }
    }

    $saved = @{}
    foreach ($key in $environment.Keys) {
        $saved[$key] = [Environment]::GetEnvironmentVariable($key)
        [Environment]::SetEnvironmentVariable($key, $environment[$key])
    }
    try {
        $process = Start-Process @startArgs
    }
    finally {
        foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key]) }
    }

    return @{ Process = $process; LogPath = $logPath; ErrPath = $errPath }
}

# 서버가 쓰고 있는 중인 파일을 읽는다(쓰기 공유 허용으로 열어야 잠김 오류가 안 난다).
function Read-SharedFile {
    param([string]$Path)

    if (-not (Test-Path $Path)) { return "" }

    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $reader = New-Object System.IO.StreamReader($stream)
        return $reader.ReadToEnd()
    }
    finally {
        $stream.Dispose()
    }
}

# 로그에 ReadyMarker가 찍힐 때까지 기다린다.
# 반환: "ready" | "exited"(뜨다가 죽음 - 포트 충돌, 설정 오류 등) | "timeout"
function Wait-ServerReady {
    param(
        [Parameter(Mandatory)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ((Read-SharedFile $LogPath).Contains($ReadyMarker)) { return "ready" }
        if ($Process.HasExited) { return "exited" }
        Start-Sleep -Milliseconds 250
    }
    return "timeout"
}

# 실패했을 때 원인을 바로 볼 수 있게 로그 끝부분을 출력한다.
function Write-LogTail {
    param([string]$Path, [int]$Lines = 20)

    $text = Read-SharedFile $Path
    if ([string]::IsNullOrWhiteSpace($text)) { return }

    Write-Host "--- $Path (마지막 ${Lines}줄) ---" -ForegroundColor DarkGray
    $text.TrimEnd() -split "`r?`n" | Select-Object -Last $Lines | ForEach-Object { Write-Host $_ }
}

# err 로그는 앞부분을 출력한다 - 처리 안 된 예외는 맨 위에 예외 종류와 메시지가 오고
# 그 아래로 스택이 길게 붙어서, 끝부분만 보면 정작 원인이 잘린다.
function Write-LogHead {
    param([string]$Path, [int]$Lines = 15)

    $text = Read-SharedFile $Path
    if ([string]::IsNullOrWhiteSpace($text)) { return }

    Write-Host "--- $Path (처음 ${Lines}줄) ---" -ForegroundColor DarkGray
    $text.TrimEnd() -split "`r?`n" | Select-Object -First $Lines | ForEach-Object { Write-Host $_ }
}

# 하네스 DLL 폴더 - Server/GameServer/Shared/Test/bin/<구성>/net8.0 (Shared/Test/Directory.Build.props와 맞춤).
function Get-HarnessOutputDir {
    param([Parameter(Mandatory)][string]$ProjectPath, [Parameter(Mandatory)][string]$Configuration)

    $gameServer = Split-Path $ProjectPath -Parent
    return Join-Path $gameServer "Shared\Test\bin\$Configuration\net8.0"
}

# -Build(dotnet run)일 때 하네스 쪽도 빌드한다 - 서버가 하네스를 참조하지 않으니 dotnet run이 같이 빌드해 주지 않는다.
# 서버별 명령 프로젝트(Shared/Test/<서버>.Harness)가 있으면 그걸(Harness.Agent도 같이 빌드됨), 없으면 Harness.Agent만.
function Build-HarnessProject {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$Configuration,
        [Parameter(Mandatory)][string]$LogDir
    )

    $sharedTest = Join-Path (Split-Path $ProjectPath -Parent) "Shared\Test"
    $project = Join-Path $sharedTest "$ProjectName.Harness\$ProjectName.Harness.csproj"
    if (-not (Test-Path $project)) { $project = Join-Path $sharedTest "Harness.Agent\Harness.Agent.csproj" }

    $base = Get-FreeLogBaseName -LogDir $LogDir -Name "$ProjectName.harness-build"
    $output = Join-Path $LogDir "$base.log"
    dotnet build "$project" --configuration $Configuration -nologo -v q *> $output
    if ($LASTEXITCODE -ne 0) {
        Write-Host "하네스 빌드 실패 ($project) - $output" -ForegroundColor Red
        Write-LogTail $output
    }
}

# 하네스 모드로 서버 하나를 띄우고 준비될 때까지 기다린다. 실패하면 로그 끝부분을 찍는다.
# 반환: @{ Process = ...; Status = "ready"|"exited"|"timeout"|"missing"|"missing-harness"; LogPath = ...; ErrPath = ... }
# (missing-harness: -HarnessAddress를 줬는데 하네스 에이전트 DLL이 없음 - 결과 파일 detail에 그대로 실린다)
function Start-HarnessServer {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$LogDir,
        [Parameter(Mandatory)][string]$Configuration,
        [Parameter(Mandatory)][int]$ReadyTimeoutSeconds,
        # 테스트 하네스 제어 서버 주소. 주면 서버가 HARNESS_NAME=<서버 이름>으로 하네스에 접속한다.
        [string]$HarnessAddress,
        [switch]$Build
    )

    $extraEnvironment = @{}
    if ($HarnessAddress) {
        $extraEnvironment["HARNESS_ADDRESS"] = $HarnessAddress
        $extraEnvironment["HARNESS_NAME"] = $ProjectName

        # 서버 프로젝트는 하네스를 참조하지 않는다 - 여기서 환경 변수로 주입한다(Harness.Agent.csproj 주석).
        #   DOTNET_STARTUP_HOOKS: .NET이 Main 전에 부름 - 하네스 폴더에서 어셈블리를 찾게 함
        #   ASPNETCORE_HOSTINGSTARTUPASSEMBLIES: ASP.NET Core가 CreateBuilder 안에서 부름 - 에이전트 등록
        $harnessDir = Get-HarnessOutputDir -ProjectPath $ProjectPath -Configuration $Configuration
        $harnessDll = Join-Path $harnessDir "Harness.Agent.dll"
        if ($Build) { Build-HarnessProject -ProjectPath $ProjectPath -ProjectName $ProjectName -Configuration $Configuration -LogDir $LogDir }
        if (-not (Test-Path $harnessDll)) {
            Write-Host "하네스 에이전트 DLL을 못 찾음: $harnessDll" -ForegroundColor Red
            Write-Host "먼저 빌드하세요(dotnet build Server\GameServer\Shared\Test\Harness.Agent, 서버별 명령이 있으면 Shared\Test\<서버>.Harness)." -ForegroundColor Red
            return @{ Process = $null; Status = "missing-harness"; LogPath = ""; ErrPath = "" }
        }
        $extraEnvironment["DOTNET_STARTUP_HOOKS"] = $harnessDll
        $extraEnvironment["ASPNETCORE_HOSTINGSTARTUPASSEMBLIES"] = "Harness.Agent"
    }

    if ($Build) {
        # 수동 모드의 -Build와 같이 dotnet run(필요하면 빌드 후 실행). 빌드 출력도 같은 로그에 남는다.
        $dotnetArgs = @("run", "--configuration", $Configuration)
    }
    else {
        $dll = Join-Path $ProjectPath "bin\$Configuration\net8.0\$ProjectName.dll"
        if (-not (Test-Path $dll)) {
            Write-Host "빌드된 DLL을 못 찾음: $dll" -ForegroundColor Red
            Write-Host "먼저 빌드하거나(dotnet build), -Build 를 붙여 실행하세요." -ForegroundColor Red
            return @{ Process = $null; Status = "missing"; LogPath = ""; ErrPath = "" }
        }
        $dotnetArgs = @("`"$dll`"")
    }

    $started = Start-HarnessProcess -Name $ProjectName -WorkingDirectory $ProjectPath `
        -DotnetArguments $dotnetArgs -LogDir $LogDir -ExtraEnvironment $extraEnvironment
    $status = Wait-ServerReady -Process $started.Process -LogPath $started.LogPath `
        -TimeoutSeconds $ReadyTimeoutSeconds

    if ($status -eq "ready") {
        Write-Host "$ProjectName 준비 완료 (PID=$($started.Process.Id), 로그=$($started.LogPath))" -ForegroundColor Green
    }
    else {
        $what = if ($status -eq "exited") { "실행 중 종료됨" } else { "${ReadyTimeoutSeconds}초 안에 준비되지 않음" }
        Write-Host "$ProjectName $what" -ForegroundColor Red
        # 프로세스가 막 죽은 직후엔 마지막 출력(예외 내용)이 아직 파일에 안 써졌을 수 있다.
        Start-Sleep -Seconds 1
        Write-LogTail $started.LogPath
        Write-LogHead $started.ErrPath
    }

    return @{ Process = $started.Process; Status = $status; LogPath = $started.LogPath; ErrPath = $started.ErrPath }
}

# 프로세스(와 그 자식들)를 강제 종료한다. 수동 모드에선 PID가 PowerShell 창이라 /T로
# 그 안의 dotnet까지 같이 끈다. 하네스 모드에선 PID가 서버(dotnet) 자체.
function Stop-ServerProcess {
    param([string]$Name, [int]$ProcessId)

    $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $proc) {
        Write-Host "$Name 이미 종료됨 (PID=$ProcessId)" -ForegroundColor Gray
        return
    }

    Write-Host "$Name 종료 중 (PID=$ProcessId)..." -ForegroundColor Cyan
    taskkill /PID $ProcessId /T /F | Out-Null

    try {
        Wait-Process -Id $ProcessId -Timeout 10 -ErrorAction SilentlyContinue
        Write-Host "$Name 종료 완료" -ForegroundColor Green
    }
    catch {
        Write-Host "$Name 종료 대기 시간 초과" -ForegroundColor Yellow
    }
}
