# start-servers.ps1
# 사용법:
#   .\start-servers.ps1          - 이미 빌드된 DLL을 그대로 실행 (빠름, 기본값)
#   .\start-servers.ps1 -Build   - 예전처럼 각 프로젝트를 dotnet run으로 실행
#                                   (코드를 새로 받았거나 처음 셋업할 때 한 번 이걸로)
# 순서: Docker → BrokerInitializer → MasterServer → MatchingServer → AccountServer →
#       LoginServer → DummySubServer → LobbyServer → GameAgent → ChatServer
# GameAgent 실행 후 Unity 에디터에서 수동으로 Play 버튼을 눌러야 한다.
#
# 하네스 모드(TestHarness가 호출할 때 - 사람이 써도 됨):
#   .\start-servers.ps1 -LogDir <폴더> [-SkipDocker] [-Only LoginServer,LobbyServer] [-ReadyTimeoutSeconds 60]
#   -LogDir      창을 띄우지 않고 각 서버의 콘솔 출력을 <폴더>\<서버>.log(.err.log)로 받는다.
#                로그는 JSON 한 줄 형식(시각 UTC 포함). PID 파일도 <폴더>\server-pids.json에 둔다.
#                고정 대기 대신 서버가 "Application started"를 찍을 때까지 기다리고, 제한 시간 안에
#                안 뜨거나 뜨다가 죽으면 로그 끝부분을 보여주고 exit 1.
#   -SkipDocker  Docker 컨테이너 시작과 BrokerInitializer를 건너뛴다(이미 떠 있고 초기화돼 있을 때).
#   -Only        지정한 서버만 띄운다(순서는 항상 위 순서를 따름). 수동 모드에서도 쓸 수 있다.
#   -HarnessAddress <주소>  각 서버가 테스트 하네스 제어 서버(예: http://localhost:9000)에 접속하게 한다
#                (서버 이름이 하네스에서 부르는 이름이 됨). -LogDir과 같이 써야 한다.
#   결과 파일: <폴더>\start-result.json - 단계별 ready/failed/skipped (server-common.ps1 "하네스 결과 파일")
#   종료: .\stop-servers.ps1 -LogDir <같은 폴더>
# 성공하면 exit 0, 실패하면 exit 1.

param(
    [switch]$Build,
    [string]$Configuration = "Debug",
    [string]$LogDir,
    [switch]$SkipDocker,
    # ValidateSet을 안 쓰고 아래에서 직접 검사한다 - powershell -File로 부르면
    # "-Only A,B"가 배열이 아니라 "A,B" 문자열 하나로 들어오기 때문(TestHarness는 -File로 부름).
    [string[]]$Only,
    [int]$ReadyTimeoutSeconds = 60,
    [string]$HarnessAddress
)

. "$PSScriptRoot\server-common.ps1"

$devTools = $PSScriptRoot
$root = Split-Path $devTools -Parent
$gameServer = "$root\Server\GameServer"
$harness = [bool]$LogDir

if ($HarnessAddress -and -not $harness) {
    Write-Host "-HarnessAddress는 -LogDir(하네스 모드)와 같이 써야 합니다." -ForegroundColor Red
    exit 1
}

if ($harness) {
    $LogDir = Resolve-LogDir $LogDir
    # dotnet run은 빌드 시간까지 포함되므로 제한 시간을 따로 안 줬으면 넉넉히.
    if ($Build -and -not $PSBoundParameters.ContainsKey("ReadyTimeoutSeconds")) { $ReadyTimeoutSeconds = 300 }

    # 이전 실행의 결과 파일이 남아 있으면 하네스가 그걸 이번 결과로 착각할 수 있으니 먼저 지운다.
    $resultFile = Join-Path $LogDir "start-result.json"
    if (Test-Path $resultFile) { Remove-Item $resultFile }
}

# 끝낼 때는 항상 이걸로 - 하네스 모드면 결과 파일을 쓰고 나간다.
function Exit-Start {
    param([int]$Code)

    if ($harness) { Save-HarnessResult -Path $resultFile -Ok ($Code -eq 0) -Action "start" }
    exit $Code
}

if ($Only) {
    $Only = @($Only | ForEach-Object { $_ -split "," } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $unknown = @($Only | Where-Object { $ServerOrder -notcontains $_ })
    if ($unknown.Count -gt 0) {
        Write-Host "-Only에 모르는 서버 이름: $($unknown -join ', ')" -ForegroundColor Red
        Write-Host "가능한 이름: $($ServerOrder -join ', ')" -ForegroundColor Red
        foreach ($name in $unknown) { Add-HarnessResult -Name $name -Status "failed" -Detail "unknown-server" }
        Exit-Start 1
    }
}

$pidFile = Get-PidFilePath -DevTools $devTools -LogDir $LogDir

# 이미 떠 있는 서버가 있으면 중단 - 이번에 쓸 PID 파일과, (하네스 모드라면) 수동 모드 PID
# 파일도 확인한다. 같은 포트를 쓰므로 어느 쪽이든 떠 있으면 새로 띄운 서버가 죽는다.
$pidFilesToCheck = @($pidFile)
if ($harness) { $pidFilesToCheck += Get-PidFilePath -DevTools $devTools }

$aliveCount = 0
foreach ($file in $pidFilesToCheck) {
    if (-not (Test-Path $file)) { continue }

    $savedPids = Read-PidFile $file
    $fileAlive = 0
    foreach ($name in $savedPids.Keys) {
        $savedPid = $savedPids[$name]
        if (Get-Process -Id $savedPid -ErrorAction SilentlyContinue) {
            Write-Host "서버가 아직 실행 중입니다: $name (PID=$savedPid, $file)" -ForegroundColor Red
            Add-HarnessResult -Name $name -Status "failed" -ProcessId $savedPid -Detail "already-running"
            $fileAlive++
        }
    }

    $aliveCount += $fileAlive
    if ($fileAlive -eq 0 -and $file -eq $pidFile) { Remove-Item $file }
}

if ($aliveCount -gt 0) {
    Write-Host ""
    Write-Host "실행 중인 서버가 있습니다. stop-servers.ps1을 먼저 실행하세요." -ForegroundColor Red
    Exit-Start 1
}

# 이번에 띄울 서버 - 순서는 항상 $ServerOrder를 따른다.
$targets = if ($Only) { $ServerOrder | Where-Object { $Only -contains $_ } } else { $ServerOrder }

$totalSteps = $ServerOrder.Count + 2   # Docker + BrokerInitializer + 서버들

if ($SkipDocker) {
    Write-Host "=== [0-1/$totalSteps] Docker / BrokerInitializer 건너뜀 (-SkipDocker) ===" -ForegroundColor DarkGray
    Add-HarnessResult -Name "Docker" -Status "skipped" -Detail "skip-docker"
    Add-HarnessResult -Name "BrokerInitializer" -Status "skipped" -Detail "skip-docker"
}
else {
    # 0. Docker 컨테이너 시작
    Write-Host "=== [0/$totalSteps] Docker 컨테이너 시작 ===" -ForegroundColor Cyan
    docker-compose -f "$devTools\docker-compose.yml" up -d
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Docker 시작 실패. 중단합니다." -ForegroundColor Red
        Add-HarnessResult -Name "Docker" -Status "failed" -Detail "docker-compose-exit=$LASTEXITCODE"
        Exit-Start 1
    }
    Add-HarnessResult -Name "Docker" -Status "ready"
    Start-Sleep -Seconds 5

    # 1. BrokerInitializer (콘솔 앱이라 완료를 기다려야 하므로 동기 실행)
    Write-Host "=== [1/$totalSteps] BrokerInitializer 실행 ===" -ForegroundColor Cyan
    $brokerDir = "$devTools\BrokerInitializer"
    $brokerDll = "$brokerDir\bin\$Configuration\net8.0\BrokerInitializer.dll"

    if (-not $Build -and -not (Test-Path $brokerDll)) {
        Write-Host "빌드된 DLL을 못 찾음: $brokerDll" -ForegroundColor Red
        Write-Host "먼저 빌드하거나(dotnet build), .\start-servers.ps1 -Build 로 실행하세요." -ForegroundColor Red
        Add-HarnessResult -Name "BrokerInitializer" -Status "failed" -Detail "missing-dll"
        Exit-Start 1
    }

    $brokerLog = ""
    $brokerErr = ""
    if ($harness) {
        $brokerArgs = if ($Build) { @("run") } else { @("`"$brokerDll`"") }
        $broker = Start-HarnessProcess -Name "BrokerInitializer" -WorkingDirectory $brokerDir `
            -DotnetArguments $brokerArgs -LogDir $LogDir -Wait
        $exitCode = $broker.Process.ExitCode
        $brokerLog = $broker.LogPath
        $brokerErr = $broker.ErrPath
        if ($exitCode -ne 0) {
            Write-LogTail $broker.LogPath
            Write-LogHead $broker.ErrPath
        }
    }
    else {
        Push-Location $brokerDir
        if ($Build) { dotnet run } else { dotnet $brokerDll }
        $exitCode = $LASTEXITCODE
        Pop-Location
    }

    if ($exitCode -ne 0) {
        Write-Host "BrokerInitializer 실패. 중단합니다." -ForegroundColor Red
        Add-HarnessResult -Name "BrokerInitializer" -Status "failed" -Detail "exit=$exitCode" -LogPath $brokerLog -ErrPath $brokerErr
        Exit-Start 1
    }
    Add-HarnessResult -Name "BrokerInitializer" -Status "ready" -LogPath $brokerLog -ErrPath $brokerErr
}

# 수동 모드: 예전과 같이 서버마다 새 PowerShell 창을 띄운다.
function Start-WindowedServer {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$ProjectName
    )

    # 창 제목을 프로젝트 이름으로 바꿔둔다 - dotnet run이 예전엔 "~ 프로젝트 빌드하는
    # 중..."을 찍어줘서 어느 창인지 구분이 됐는데, DLL을 바로 실행하면 그 출력이 없어서
    # 창만 보고는 구분이 안 됨. 작업표시줄/Alt-Tab에서도 바로 보이게 하려고 이렇게 함.
    $titleCommand = "`$host.UI.RawUI.WindowTitle = '$ProjectName'"

    if ($Build) {
        return Start-Process powershell -ArgumentList "-NoExit", "-Command", "$titleCommand; cd '$ProjectPath'; dotnet run" -PassThru
    }

    $dll = "$ProjectPath\bin\$Configuration\net8.0\$ProjectName.dll"
    if (-not (Test-Path $dll)) {
        Write-Host "빌드된 DLL을 못 찾음: $dll" -ForegroundColor Red
        Write-Host "먼저 빌드하거나(dotnet build), .\start-servers.ps1 -Build 로 실행하세요." -ForegroundColor Red
        return $null
    }

    return Start-Process powershell -ArgumentList "-NoExit", "-Command", "$titleCommand; cd '$ProjectPath'; dotnet '$dll'" -PassThru
}

$serverPids = @{}

foreach ($name in $targets) {
    $step = [array]::IndexOf($ServerOrder, $name) + 2
    Write-Host "=== [$step/$totalSteps] $name 실행 ===" -ForegroundColor Cyan

    $projectPath = "$gameServer\$name"

    if ($harness) {
        $result = Start-HarnessServer -ProjectPath $projectPath -ProjectName $name -LogDir $LogDir `
            -Configuration $Configuration -ReadyTimeoutSeconds $ReadyTimeoutSeconds `
            -HarnessAddress $HarnessAddress -Build:$Build
        $process = $result.Process
        $ok = $result.Status -eq "ready"

        $processId = if ($null -ne $process) { $process.Id } else { 0 }
        if ($ok) {
            Add-HarnessResult -Name $name -Status "ready" -ProcessId $processId -LogPath $result.LogPath -ErrPath $result.ErrPath
        }
        else {
            # Status: exited(뜨다가 죽음) | timeout | missing(빌드된 DLL 없음)
            $detail = if ($result.Status -eq "missing") { "missing-dll" } else { $result.Status }
            Add-HarnessResult -Name $name -Status "failed" -ProcessId $processId -Detail $detail `
                -LogPath $result.LogPath -ErrPath $result.ErrPath
        }
    }
    else {
        $process = Start-WindowedServer -ProjectPath $projectPath -ProjectName $name
        $ok = $null -ne $process
    }

    # 하나 띄울 때마다 바로 저장 - 중간에 실패해도 이미 뜬 서버는 stop-servers.ps1로 정리된다.
    if ($null -ne $process) {
        $serverPids[$name] = $process.Id
        Save-PidFile -Map $serverPids -Path $pidFile
    }

    if (-not $ok) {
        $stopCommand = if ($harness) { ".\stop-servers.ps1 -LogDir `"$LogDir`"" } else { ".\stop-servers.ps1" }
        Write-Host ""
        Write-Host "$name 시작 실패. 중단합니다. 이미 뜬 서버 정리: $stopCommand" -ForegroundColor Red

        # 실패 지점 뒤로 못 띄운 서버들도 결과에 남긴다 - 하네스가 "어디서 멈췄는지" 바로 알 수 있게.
        $index = [array]::IndexOf(@($targets), $name)
        foreach ($rest in @($targets) | Select-Object -Skip ($index + 1)) {
            Add-HarnessResult -Name $rest -Status "skipped" -Detail "aborted"
        }
        Exit-Start 1
    }

    # 수동 모드는 준비 여부를 알 방법이 없어 예전처럼 고정 대기.
    if (-not $harness) { Start-Sleep -Seconds 3 }
}

Write-Host ""
Write-Host "=== 모든 서버 실행 완료 ===" -ForegroundColor Green
Write-Host "PID 파일 저장됨: $pidFile" -ForegroundColor Gray

if ($harness) {
    Write-Host "로그 폴더: $LogDir" -ForegroundColor Gray
    Write-Host "종료하려면: .\stop-servers.ps1 -LogDir `"$LogDir`"" -ForegroundColor Yellow
}
else {
    Write-Host ""
    Write-Host "이제 Unity 에디터에서 Play 버튼을 눌러주세요." -ForegroundColor Yellow
    Write-Host "종료하려면: .\stop-servers.ps1" -ForegroundColor Yellow
}

Exit-Start 0
