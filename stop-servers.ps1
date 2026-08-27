# stop-servers.ps1
# 사용법: .\stop-servers.ps1
# 역순으로 종료: ChatServer → GameAgent → LobbyServer → DummySubServer → MatchingServer → MasterServer → Docker

$devTools = $PSScriptRoot
$pidFile = "$devTools\server-pids.json"

if (-not (Test-Path $pidFile)) {
    Write-Host "PID 파일이 없습니다. 서버가 실행 중이지 않거나 이미 종료됐습니다." -ForegroundColor Yellow
    exit 0
}

$savedPids = Get-Content $pidFile | ConvertFrom-Json

$stopOrder = @("ChatServer", "GameAgent", "LobbyServer", "DummySubServer", "MatchingServer", "MasterServer")

foreach ($name in $stopOrder) {
    $savedPid = $savedPids.$name
    if ($null -eq $savedPid) { continue }

    $proc = Get-Process -Id $savedPid -ErrorAction SilentlyContinue
    if ($null -eq $proc) {
        Write-Host "$name 이미 종료됨 (PID=$savedPid)" -ForegroundColor Gray
        continue
    }

    Write-Host "$name 종료 중 (PID=$savedPid)..." -ForegroundColor Cyan
    taskkill /PID $savedPid /T /F | Out-Null

    try {
        Wait-Process -Id $savedPid -Timeout 10 -ErrorAction SilentlyContinue
        Write-Host "$name 종료 완료" -ForegroundColor Green
    } catch {
        Write-Host "$name 종료 대기 시간 초과" -ForegroundColor Yellow
    }

    Start-Sleep -Seconds 1
}

Remove-Item $pidFile
Write-Host ""

Write-Host "=== Docker 컨테이너 종료 ===" -ForegroundColor Cyan
docker-compose -f "$devTools\docker-compose.yml" down
Write-Host ""
Write-Host "=== 모든 서버 종료 완료 ===" -ForegroundColor Green
