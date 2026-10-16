# stop-servers.ps1
# 사용법: .\stop-servers.ps1
# 역순으로 종료: ChatServer → GameAgent → LobbyServer → DummySubServer → LoginServer →
#              AccountServer → MatchingServer → MasterServer → Docker
#
# 하네스 모드:
#   .\stop-servers.ps1 -LogDir <start-servers.ps1에 준 폴더> [-SkipDocker]
#   -LogDir      그 폴더의 server-pids.json에 있는 서버를 끈다(수동 모드로 띄운 서버는 안 건드림).
#   -SkipDocker  Docker 컨테이너는 내리지 않는다 - 시나리오마다 서버만 껐다 켤 때.
# 주의: 강제 종료(taskkill /F)라 서버가 마지막 순간에 찍던 로그 몇 줄은 파일에 안 남을 수 있다.

param(
    [string]$LogDir,
    [switch]$SkipDocker
)

. "$PSScriptRoot\server-common.ps1"

$devTools = $PSScriptRoot
$pidFile = Get-PidFilePath -DevTools $devTools -LogDir $LogDir

if (Test-Path $pidFile) {
    $savedPids = Read-PidFile $pidFile

    $stopOrder = @($ServerOrder)
    [array]::Reverse($stopOrder)

    foreach ($name in $stopOrder) {
        if (-not $savedPids.ContainsKey($name)) { continue }

        Stop-ServerProcess -Name $name -ProcessId $savedPids[$name]
        Start-Sleep -Seconds 1
    }

    Remove-Item $pidFile
    Write-Host ""
}
else {
    Write-Host "PID 파일이 없습니다. 서버가 실행 중이지 않거나 이미 종료됐습니다. ($pidFile)" -ForegroundColor Yellow

    # 수동 모드는 예전처럼 여기서 끝낸다. 하네스 모드는 서버가 하나도 뜨기 전에 실패한 경우
    # (예: BrokerInitializer 실패)에도 Docker는 올라가 있으므로 계속 진행해서 정리한다.
    if (-not $LogDir) { exit 0 }
}

if ($SkipDocker) {
    Write-Host "=== Docker 컨테이너는 그대로 둠 (-SkipDocker) ===" -ForegroundColor DarkGray
}
else {
    Write-Host "=== Docker 컨테이너 종료 ===" -ForegroundColor Cyan
    docker-compose -f "$devTools\docker-compose.yml" down
}

Write-Host ""
Write-Host "=== 모든 서버 종료 완료 ===" -ForegroundColor Green
