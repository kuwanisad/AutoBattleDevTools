# control-server.ps1
# 사용법:
#   .\control-server.ps1 -ServerName MatchingServer -Action Kill      # 그냥 죽이기
#   .\control-server.ps1 -ServerName MatchingServer -Action Restart   # 죽이고 다시 띄우기
#   .\control-server.ps1 -ServerName MatchingServer -Action Start     # 새로 띄우기(안 떠 있을 때)
#
# S2(장애 주입) 시나리오처럼 서버 하나만 콕 집어 죽이거나 재시작해야 할 때 쓴다.
# server-pids.json을 start-servers.ps1/stop-servers.ps1과 그대로 공유하므로, 이 스크립트로
# 죽이거나 새로 띄운 것도 stop-servers.ps1이 정상적으로 인식한다.
# 항상 이미 빌드된 DLL을 실행한다(-Build 옵션 없음) - 필요하면 먼저 dotnet build.
#
# 하네스 모드: -LogDir <start-servers.ps1에 준 폴더> [-ReadyTimeoutSeconds 60]
#   그 폴더의 PID 파일을 쓰고, 새로 띄운 서버는 창 없이 같은 폴더에 로그를 남긴다.
#   재시작하면 이전 로그를 덮어쓰지 않고 <서버>.2.log, <서버>.3.log ... 로 이어서 남긴다.
#   Start/Restart는 서버가 준비될 때까지 기다리고, 실패하면 exit 1.
#   -HarnessAddress <주소>를 주면 새로 띄운 서버도 테스트 하네스에 접속한다(start-servers.ps1과 같은 값).
#   결과 파일: <폴더>\control-result.json - Kill은 killed/not-running, Start는 ready/failed
#   (Restart는 두 줄). 형식은 server-common.ps1 "하네스 결과 파일".

param(
    [Parameter(Mandatory)]
    [ValidateSet("MasterServer", "MatchingServer", "AccountServer", "LoginServer",
                 "DummySubServer", "LobbyServer", "GameAgent", "ChatServer")]
    [string]$ServerName,

    [Parameter(Mandatory)]
    [ValidateSet("Kill", "Restart", "Start")]
    [string]$Action,

    [string]$Configuration = "Debug",

    [string]$LogDir,
    [int]$ReadyTimeoutSeconds = 60,
    [string]$HarnessAddress
)

. "$PSScriptRoot\server-common.ps1"

$devTools = $PSScriptRoot
$root = Split-Path $devTools -Parent
$gameServer = "$root\Server\GameServer"
$harness = [bool]$LogDir
if ($harness) {
    $LogDir = Resolve-LogDir $LogDir
    $resultFile = Join-Path $LogDir "control-result.json"
    if (Test-Path $resultFile) { Remove-Item $resultFile }
}
$pidFile = Get-PidFilePath -DevTools $devTools -LogDir $LogDir

# 끝낼 때는 항상 이걸로 - 하네스 모드면 결과 파일을 쓰고 나간다.
function Exit-Control {
    param([int]$Code)

    if ($harness) { Save-HarnessResult -Path $resultFile -Ok ($Code -eq 0) -Action $Action.ToLowerInvariant() }
    exit $Code
}

$serverPids = Read-PidFile $pidFile

function Stop-Target {
    if (-not $serverPids.ContainsKey($ServerName)) {
        Write-Host "$ServerName 은 PID 파일에 없습니다(안 떠 있거나 start-servers.ps1로 안 띄움)." -ForegroundColor Yellow
        Add-HarnessResult -Name $ServerName -Status "not-running" -Detail "not-in-pid-file"
        return
    }

    $targetPid = [int]$serverPids[$ServerName]
    $wasAlive = $null -ne (Get-Process -Id $targetPid -ErrorAction SilentlyContinue)
    Stop-ServerProcess -Name $ServerName -ProcessId $targetPid
    if ($wasAlive) {
        Add-HarnessResult -Name $ServerName -Status "killed" -ProcessId $targetPid
    }
    else {
        Add-HarnessResult -Name $ServerName -Status "not-running" -ProcessId $targetPid -Detail "already-exited"
    }

    $serverPids.Remove($ServerName)
    Save-PidFile -Map $serverPids -Path $pidFile
}

function Start-Target {
    $projectPath = "$gameServer\$ServerName"

    if ($harness) {
        $result = Start-HarnessServer -ProjectPath $projectPath -ProjectName $ServerName -LogDir $LogDir `
            -Configuration $Configuration -ReadyTimeoutSeconds $ReadyTimeoutSeconds -HarnessAddress $HarnessAddress
        $processId = 0
        if ($null -ne $result.Process) {
            $processId = $result.Process.Id
            $serverPids[$ServerName] = $processId
            Save-PidFile -Map $serverPids -Path $pidFile
        }
        if ($result.Status -ne "ready") {
            $detail = if ($result.Status -eq "missing") { "missing-dll" } else { $result.Status }
            Add-HarnessResult -Name $ServerName -Status "failed" -ProcessId $processId -Detail $detail `
                -LogPath $result.LogPath -ErrPath $result.ErrPath
            Exit-Control 1
        }
        Add-HarnessResult -Name $ServerName -Status "ready" -ProcessId $processId `
            -LogPath $result.LogPath -ErrPath $result.ErrPath
        return
    }

    $dll = "$projectPath\bin\$Configuration\net8.0\$ServerName.dll"
    if (-not (Test-Path $dll)) {
        Write-Host "빌드된 DLL을 못 찾음: $dll - 먼저 빌드하세요." -ForegroundColor Red
        exit 1
    }

    $titleCommand = "`$host.UI.RawUI.WindowTitle = '$ServerName'"
    $p = Start-Process powershell -ArgumentList "-NoExit", "-Command", "$titleCommand; cd '$projectPath'; dotnet '$dll'" -PassThru
    $serverPids[$ServerName] = $p.Id
    Save-PidFile -Map $serverPids -Path $pidFile
    Write-Host "$ServerName 시작됨 (PID=$($p.Id))" -ForegroundColor Green
}

switch ($Action) {
    "Kill"    { Stop-Target }
    "Start"   { Start-Target }
    "Restart" { Stop-Target; Start-Sleep -Seconds 1; Start-Target }
}

Exit-Control 0
