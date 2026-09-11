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

param(
    [Parameter(Mandatory)]
    [ValidateSet("MasterServer", "MatchingServer", "AccountServer", "LoginServer",
                 "DummySubServer", "LobbyServer", "GameAgent", "ChatServer")]
    [string]$ServerName,

    [Parameter(Mandatory)]
    [ValidateSet("Kill", "Restart", "Start")]
    [string]$Action,

    [string]$Configuration = "Debug"
)

$devTools = $PSScriptRoot
$root = Split-Path $devTools -Parent
$gameServer = "$root\Server\GameServer"
$pidFile = "$devTools\server-pids.json"

function Get-SavedPids {
    if (Test-Path $pidFile) {
        $obj = Get-Content $pidFile | ConvertFrom-Json
        $map = @{}
        foreach ($entry in $obj.PSObject.Properties) { $map[$entry.Name] = $entry.Value }
        return $map
    }
    return @{}
}

function Save-Pids($map) {
    $map | ConvertTo-Json | Set-Content $pidFile
}

$serverPids = Get-SavedPids

function Stop-Target {
    if (-not $serverPids.ContainsKey($ServerName)) {
        Write-Host "$ServerName 은 PID 파일에 없습니다(안 떠 있거나 start-servers.ps1로 안 띄움)." -ForegroundColor Yellow
        return
    }

    $targetPid = $serverPids[$ServerName]
    $proc = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
    if ($null -eq $proc) {
        Write-Host "$ServerName 이미 종료됨 (PID=$targetPid)" -ForegroundColor Gray
    } else {
        Write-Host "$ServerName 종료 중 (PID=$targetPid)..." -ForegroundColor Cyan
        taskkill /PID $targetPid /T /F | Out-Null
        Wait-Process -Id $targetPid -Timeout 10 -ErrorAction SilentlyContinue
        Write-Host "$ServerName 종료 완료" -ForegroundColor Green
    }

    $serverPids.Remove($ServerName)
    Save-Pids $serverPids
}

function Start-Target {
    $projectPath = "$gameServer\$ServerName"
    $dll = "$projectPath\bin\$Configuration\net8.0\$ServerName.dll"
    if (-not (Test-Path $dll)) {
        Write-Host "빌드된 DLL을 못 찾음: $dll - 먼저 빌드하세요." -ForegroundColor Red
        exit 1
    }

    $titleCommand = "`$host.UI.RawUI.WindowTitle = '$ServerName'"
    $p = Start-Process powershell -ArgumentList "-NoExit", "-Command", "$titleCommand; cd '$projectPath'; dotnet '$dll'" -PassThru
    $serverPids[$ServerName] = $p.Id
    Save-Pids $serverPids
    Write-Host "$ServerName 시작됨 (PID=$($p.Id))" -ForegroundColor Green
}

switch ($Action) {
    "Kill"    { Stop-Target }
    "Start"   { Start-Target }
    "Restart" { Stop-Target; Start-Sleep -Seconds 1; Start-Target }
}
