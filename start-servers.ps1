# start-servers.ps1
# 사용법: .\start-servers.ps1
# 순서: Docker → BrokerInitializer → MasterServer → DummySubServer → LobbyServer → GameAgent
# GameAgent 실행 후 Unity 에디터에서 수동으로 Play 버튼을 눌러야 한다.

$root = "C:\Users\rlawh\Desktop\Main"
$gameServer = "$root\AutoBattlerServer\GameServer"
$devTools = "$root\AutoBattleDevTools"
$pidFile = "$devTools\server-pids.json"

# 이전 서버가 아직 살아있는지 확인
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

    # 모두 종료됐으면 PID 파일 삭제
    Remove-Item $pidFile
}

# 0. Docker 컨테이너 시작
Write-Host "=== [0/5] Docker 컨테이너 시작 ===" -ForegroundColor Cyan
docker-compose -f "$devTools\docker-compose.yml" up -d
if ($LASTEXITCODE -ne 0) {
    Write-Host "Docker 시작 실패. 중단합니다." -ForegroundColor Red
    exit 1
}
Start-Sleep -Seconds 5

# 1. BrokerInitializer - 토픽/큐 초기화 (완료될 때까지 기다림)
Write-Host "=== [1/5] BrokerInitializer 실행 ===" -ForegroundColor Cyan
Push-Location "$devTools\BrokerInitializer"
dotnet run
Pop-Location

if ($LASTEXITCODE -ne 0) {
    Write-Host "BrokerInitializer 실패. 중단합니다." -ForegroundColor Red
    exit 1
}

# PID 저장용 해시테이블
$serverPids = @{}

# 2. MasterServer
Write-Host "=== [2/5] MasterServer 실행 ===" -ForegroundColor Cyan
$p = Start-Process powershell -ArgumentList "-NoExit", "-Command", "cd '$gameServer\MasterServer'; dotnet run" -PassThru
$serverPids["MasterServer"] = $p.Id
Start-Sleep -Seconds 3

# 3. DummySubServer
Write-Host "=== [3/5] DummySubServer 실행 ===" -ForegroundColor Cyan
$p = Start-Process powershell -ArgumentList "-NoExit", "-Command", "cd '$gameServer\DummySubServer'; dotnet run" -PassThru
$serverPids["DummySubServer"] = $p.Id
Start-Sleep -Seconds 3

# 4. LobbyServer
Write-Host "=== [4/5] LobbyServer 실행 ===" -ForegroundColor Cyan
$p = Start-Process powershell -ArgumentList "-NoExit", "-Command", "cd '$gameServer\LobbyServer'; dotnet run" -PassThru
$serverPids["LobbyServer"] = $p.Id
Start-Sleep -Seconds 3

# 5. GameAgent
Write-Host "=== [5/5] GameAgent 실행 ===" -ForegroundColor Cyan
$p = Start-Process powershell -ArgumentList "-NoExit", "-Command", "cd '$gameServer\GameAgent'; dotnet run" -PassThru
$serverPids["GameAgent"] = $p.Id
Start-Sleep -Seconds 3

# PID 파일 저장
$serverPids | ConvertTo-Json | Set-Content $pidFile
Write-Host ""
Write-Host "=== 모든 서버 실행 완료 ===" -ForegroundColor Green
Write-Host "PID 파일 저장됨: $pidFile" -ForegroundColor Gray
Write-Host ""
Write-Host "이제 Unity 에디터에서 Play 버튼을 눌러주세요." -ForegroundColor Yellow
Write-Host "종료하려면: .\stop-servers.ps1" -ForegroundColor Yellow
