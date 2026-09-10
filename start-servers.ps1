# start-servers.ps1
# 사용법:
#   .\start-servers.ps1          - 이미 빌드된 DLL을 그대로 실행 (빠름, 기본값)
#   .\start-servers.ps1 -Build   - 예전처럼 각 프로젝트를 dotnet run으로 실행
#                                   (코드를 새로 받았거나 처음 셋업할 때 한 번 이걸로)
# 순서: Docker → BrokerInitializer → MasterServer → MatchingServer → AccountServer →
#       LoginServer → DummySubServer → LobbyServer → GameAgent → ChatServer
# GameAgent 실행 후 Unity 에디터에서 수동으로 Play 버튼을 눌러야 한다.

param(
    [switch]$Build,
    [string]$Configuration = "Debug"
)

$devTools = $PSScriptRoot
$root = Split-Path $devTools -Parent
$gameServer = "$root\Server\GameServer"
$pidFile = "$devTools\server-pids.json"

# 이미 빌드된 DLL을 dotnet 호스트로 바로 실행한다(빌드 확인 자체를 안 거침, dotnet run보다
# 훨씬 빠름). -Build가 지정되면 예전 방식(dotnet run - 매번 최신 상태 확인 + 필요시 빌드)으로
# 되돌아간다. 둘 다 새 PowerShell 창에서 Start-Process로 띄우는 건 동일.
function Start-ServerProcess {
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
        exit 1
    }

    return Start-Process powershell -ArgumentList "-NoExit", "-Command", "$titleCommand; cd '$ProjectPath'; dotnet '$dll'" -PassThru
}

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
Write-Host "=== [0/10] Docker 컨테이너 시작 ===" -ForegroundColor Cyan
docker-compose -f "$devTools\docker-compose.yml" up -d
if ($LASTEXITCODE -ne 0) {
    Write-Host "Docker 시작 실패. 중단합니다." -ForegroundColor Red
    exit 1
}
Start-Sleep -Seconds 5

# 1. BrokerInitializer (콘솔 앱이라 완료를 기다려야 하므로 Start-Process가 아니라 동기 실행)
Write-Host "=== [1/10] BrokerInitializer 실행 ===" -ForegroundColor Cyan
if ($Build) {
    Push-Location "$devTools\BrokerInitializer"
    dotnet run
    $exitCode = $LASTEXITCODE
    Pop-Location
} else {
    $brokerDll = "$devTools\BrokerInitializer\bin\$Configuration\net8.0\BrokerInitializer.dll"
    if (-not (Test-Path $brokerDll)) {
        Write-Host "빌드된 DLL을 못 찾음: $brokerDll" -ForegroundColor Red
        Write-Host "먼저 빌드하거나(dotnet build), .\start-servers.ps1 -Build 로 실행하세요." -ForegroundColor Red
        exit 1
    }
    Push-Location "$devTools\BrokerInitializer"
    dotnet $brokerDll
    $exitCode = $LASTEXITCODE
    Pop-Location
}

if ($exitCode -ne 0) {
    Write-Host "BrokerInitializer 실패. 중단합니다." -ForegroundColor Red
    exit 1
}

$serverPids = @{}

# 2. MasterServer
Write-Host "=== [2/10] MasterServer 실행 ===" -ForegroundColor Cyan
$p = Start-ServerProcess -ProjectPath "$gameServer\MasterServer" -ProjectName "MasterServer"
$serverPids["MasterServer"] = $p.Id
Start-Sleep -Seconds 3

# 3. MatchingServer (마스터 서버 직후 실행 - 마스터가 주소를 메인 서버들에 전달)
Write-Host "=== [3/10] MatchingServer 실행 ===" -ForegroundColor Cyan
$p = Start-ServerProcess -ProjectPath "$gameServer\MatchingServer" -ProjectName "MatchingServer"
$serverPids["MatchingServer"] = $p.Id
Start-Sleep -Seconds 3

# 4. AccountServer (로그인 서버가 계정 검증/생성에 씀 - 로그인 서버보다 먼저 떠 있어야 함)
Write-Host "=== [4/10] AccountServer 실행 ===" -ForegroundColor Cyan
$p = Start-ServerProcess -ProjectPath "$gameServer\AccountServer" -ProjectName "AccountServer"
$serverPids["AccountServer"] = $p.Id
Start-Sleep -Seconds 3

# 5. LoginServer (클라 최초 진입점 - AccountServer/MatchingServer 주소가 필요하므로 그 뒤에 실행)
Write-Host "=== [5/10] LoginServer 실행 ===" -ForegroundColor Cyan
$p = Start-ServerProcess -ProjectPath "$gameServer\LoginServer" -ProjectName "LoginServer"
$serverPids["LoginServer"] = $p.Id
Start-Sleep -Seconds 3

# 6. DummySubServer
Write-Host "=== [6/10] DummySubServer 실행 ===" -ForegroundColor Cyan
$p = Start-ServerProcess -ProjectPath "$gameServer\DummySubServer" -ProjectName "DummySubServer"
$serverPids["DummySubServer"] = $p.Id
Start-Sleep -Seconds 3

# 7. LobbyServer
Write-Host "=== [7/10] LobbyServer 실행 ===" -ForegroundColor Cyan
$p = Start-ServerProcess -ProjectPath "$gameServer\LobbyServer" -ProjectName "LobbyServer"
$serverPids["LobbyServer"] = $p.Id
Start-Sleep -Seconds 3

# 8. GameAgent
Write-Host "=== [8/10] GameAgent 실행 ===" -ForegroundColor Cyan
$p = Start-ServerProcess -ProjectPath "$gameServer\GameAgent" -ProjectName "GameAgent"
$serverPids["GameAgent"] = $p.Id
Start-Sleep -Seconds 3

# 9. ChatServer
Write-Host "=== [9/10] ChatServer 실행 ===" -ForegroundColor Cyan
$p = Start-ServerProcess -ProjectPath "$gameServer\ChatServer" -ProjectName "ChatServer"
$serverPids["ChatServer"] = $p.Id
Start-Sleep -Seconds 3

$serverPids | ConvertTo-Json | Set-Content $pidFile
Write-Host ""
Write-Host "=== 모든 서버 실행 완료 ===" -ForegroundColor Green
Write-Host "PID 파일 저장됨: $pidFile" -ForegroundColor Gray
Write-Host ""
Write-Host "이제 Unity 에디터에서 Play 버튼을 눌러주세요." -ForegroundColor Yellow
Write-Host "종료하려면: .\stop-servers.ps1" -ForegroundColor Yellow
