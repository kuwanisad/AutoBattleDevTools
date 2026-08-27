# start-servers.ps1
# 사용법: .\start-servers.ps1
# 순서: Docker → BrokerInitializer → MasterServer → MatchingServer → DummySubServer → LobbyServer → GameAgent → ChatServer
# GameAgent 실행 후 Unity 에디터에서 수동으로 Play 버튼을 눌러야 한다.

$devTools = $PSScriptRoot
$root = Split-Path $devTools -Parent
$gameServer = "$root\Server\GameServer"
$pidFile = "$devTools\server-pids.json"

if (Test-Path $pidFile) {
    $savedPids = Get-Content $pidFile | ConvertFrom-Json
    $aliveCount = 0

    foreach ($entry in $savedPids.PSObject.Properties) {
        $savedPid = $entry.Value
        if (Get-Process -Id $savedPid -ErrorAction SilentlyContinue) {
            Write-Host "서버가 아직 실행 중입니다: $($entry.Name) (PID=$savedPid)" -ForegroundColor Red
            $aliveCount++
        }
    }

    if ($aliveCount -gt 0) {
        Write-Host ""
        Write-Host "실행 중인 서버가 있습니다. stop-servers.ps1을 먼저 실행하세요." -ForegroundColor Red
        exit 1
    }

    Remove-Item $pidFile
}

# 0. Docker 컨테이너 시작
Write-Host "=== [0/8] Docker 컨테이너 시작 ===" -ForegroundColor Cyan
docker-compose -f "$devTools\docker-compose.yml" up -d
if ($LASTEXITCODE -ne 0) {
    Write-Host "Docker 시작 실패. 중단합니다." -ForegroundColor Red
    exit 1
}
Start-Sleep -Seconds 5

# 1. BrokerInitializer
Write-Host "=== [1/8] BrokerInitializer 실행 ===" -ForegroundColor Cyan
Push-Location "$devTools\BrokerInitializer"
dotnet run
Pop-Location

if ($LASTEXITCODE -ne 0) {
    Write-Host "BrokerInitializer 실패. 중단합니다." -ForegroundColor Red
    exit 1
}

$serverPids = @{}

# 2. MasterServer
Write-Host "=== [2/8] MasterServer 실행 ===" -ForegroundColor Cyan
$p = Start-Process powershell -ArgumentList "-NoExit", "-Command", "cd '$gameServer\MasterServer'; dotnet run" -PassThru
$serverPids["MasterServer"] = $p.Id
Start-Sleep -Seconds 3

# 3. MatchingServer (마스터 서버 직후 실행 - 마스터가 주소를 메인 서버들에 전달)
Write-Host "=== [3/8] MatchingServer 실행 ===" -ForegroundColor Cyan
$p = Start-Process powershell -ArgumentList "-NoExit", "-Command", "cd '$gameServer\MatchingServer'; dotnet run" -PassThru
$serverPids["MatchingServer"] = $p.Id
Start-Sleep -Seconds 3

# 4. DummySubServer
Write-Host "=== [4/8] DummySubServer 실행 ===" -ForegroundColor Cyan
$p = Start-Process powershell -ArgumentList "-NoExit", "-Command", "cd '$gameServer\DummySubServer'; dotnet run" -PassThru
$serverPids["DummySubServer"] = $p.Id
Start-Sleep -Seconds 3

# 5. LobbyServer
Write-Host "=== [5/8] LobbyServer 실행 ===" -ForegroundColor Cyan
$p = Start-Process powershell -ArgumentList "-NoExit", "-Command", "cd '$gameServer\LobbyServer'; dotnet run" -PassThru
$serverPids["LobbyServer"] = $p.Id
Start-Sleep -Seconds 3

# 6. GameAgent
Write-Host "=== [6/8] GameAgent 실행 ===" -ForegroundColor Cyan
$p = Start-Process powershell -ArgumentList "-NoExit", "-Command", "cd '$gameServer\GameAgent'; dotnet run" -PassThru
$serverPids["GameAgent"] = $p.Id
Start-Sleep -Seconds 3

# 7. ChatServer
Write-Host "=== [7/8] ChatServer 실행 ===" -ForegroundColor Cyan
$p = Start-Process powershell -ArgumentList "-NoExit", "-Command", "cd '$gameServer\ChatServer'; dotnet run" -PassThru
$serverPids["ChatServer"] = $p.Id
Start-Sleep -Seconds 3

$serverPids | ConvertTo-Json | Set-Content $pidFile
Write-Host ""
Write-Host "=== 모든 서버 실행 완료 ===" -ForegroundColor Green
Write-Host "PID 파일 저장됨: $pidFile" -ForegroundColor Gray
Write-Host ""
Write-Host "이제 Unity 에디터에서 Play 버튼을 눌러주세요." -ForegroundColor Yellow
Write-Host "종료하려면: .\stop-servers.ps1" -ForegroundColor Yellow
