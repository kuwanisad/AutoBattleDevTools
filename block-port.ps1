# block-port.ps1
# 사용법: .\block-port.ps1 -Port 7777 -DurationSeconds 10
#
# S2의 재접속 관련 항목(3.1/3.2/3.4)용 - 지정한 시간 동안 그 포트로 나가는 연결을
# Windows 방화벽으로 막았다가 시간이 지나면 자동으로 해제한다. 인게임 서버(NGO/
# UnityTransport, 보통 7777)를 이 방식으로 끊으면 클라 입장에서는 진짜 네트워크 장애와
# 구분이 안 되므로, ClientInstance.OnNgoClientDisconnected의 실제 재접속 경로를 그대로
# 탄다(별도 시뮬레이션 코드 필요 없음).
#
# 관리자 권한 PowerShell에서 실행해야 한다(New-NetFirewallRule 요구사항).
#
# 참고: 재접속 유예 시간(GameServerHandler.ReconnectGracePeriod)은 30초다.
#   - 3.1(유예 내 재접속): DurationSeconds를 30보다 짧게(예: 5~10)
#   - 3.2(유예 초과): DurationSeconds를 30보다 길게(예: 40)
# 클라의 빠른 재접속 시도 자체는 끊긴 즉시 자동으로 일어나므로, 짧게 끊으면 그 시도가
# 네트워크가 막힌 도중에 나가서 실패할 수 있다 - 정확한 타이밍은 실제로 한번 돌려보면서
# DurationSeconds를 조절해야 할 수 있다(그 시도 자체가 언제 나가는지는 클라 콘솔의
# "재접속 가능한 방 - 빠른 경로로 직접 재시도" 로그로 확인).

param(
    [Parameter(Mandatory)][int]$Port,
    [Parameter(Mandatory)][int]$DurationSeconds
)

$ruleNameTcp = "S2-BlockPort-$Port-TCP"
$ruleNameUdp = "S2-BlockPort-$Port-UDP"

# 혹시 이전 실행이 비정상 종료돼 규칙이 남아있을 경우를 대비해 먼저 정리.
Remove-NetFirewallRule -DisplayName $ruleNameTcp -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName $ruleNameUdp -ErrorAction SilentlyContinue

New-NetFirewallRule -DisplayName $ruleNameTcp -Direction Outbound -Protocol TCP -RemotePort $Port -Action Block | Out-Null
New-NetFirewallRule -DisplayName $ruleNameUdp -Direction Outbound -Protocol UDP -RemotePort $Port -Action Block | Out-Null

Write-Host "포트 $Port 차단 시작 ($DurationSeconds 초 동안)..." -ForegroundColor Cyan
Start-Sleep -Seconds $DurationSeconds

Remove-NetFirewallRule -DisplayName $ruleNameTcp -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName $ruleNameUdp -ErrorAction SilentlyContinue

Write-Host "포트 $Port 차단 해제" -ForegroundColor Green
