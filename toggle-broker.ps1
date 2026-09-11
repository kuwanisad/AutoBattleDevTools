# toggle-broker.ps1
# 사용법:
#   .\toggle-broker.ps1 -Service redis -Action Stop
#   .\toggle-broker.ps1 -Service redis -Action Start
#   .\toggle-broker.ps1 -Service all -Action Stop
#
# S2의 "Kafka/RabbitMQ/Redis가 죽어있는 상태에서 서버 기동/운영" 테스트용 - 컨테이너를
# 통째로 내렸다 올리는 게 아니라(docker-compose down/up은 볼륨/네트워크까지 다시 만듦),
# stop/start만 해서 딱 그 컨테이너 하나만 껐다 켠다.

param(
    [Parameter(Mandatory)]
    [ValidateSet("redis", "kafka", "rabbitmq", "all")]
    [string]$Service,

    [Parameter(Mandatory)]
    [ValidateSet("Stop", "Start")]
    [string]$Action
)

$devTools = $PSScriptRoot
$composeFile = "$devTools\docker-compose.yml"
$dockerAction = $Action.ToLower()

if ($Service -eq "all") {
    docker-compose -f $composeFile $dockerAction
} else {
    docker-compose -f $composeFile $dockerAction $Service
}

if ($LASTEXITCODE -ne 0) {
    Write-Host "$Service $Action 실패" -ForegroundColor Red
    exit 1
}

Write-Host "$Service 컨테이너 $Action 완료" -ForegroundColor Green
