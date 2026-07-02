using BrokerInitializer;

// ================================================================
// 테스트 전 브로커 초기화 설정
//
// 주의: 이 프로그램은 기존 토픽/큐를 삭제하고 재생성합니다.
//       반드시 개발/테스트 환경에서만 실행하세요.
//
// 설정 변경 방법:
//   - Kafka 토픽 추가/제거: .AddTopic(...)
//   - RabbitMQ 큐 추가/제거: .AddQueue(...)
//   - Fanout exchange 추가/제거: .AddFanout(...)
//   - 브로커 주소 변경: .Server(...)
// ================================================================

await BrokerInitializer.BrokerInitializer.Create()
    .Kafka(k => k
        .Server("localhost:9092")
        .AddTopic("game-events",   partitions: 1)   // 결제 로그, 매치 결과 등
        .AddTopic("match-results", partitions: 1))  // 매치 종료 이벤트
    .RabbitMQ(r => r
        .Server("localhost", port: 5672)
        .Credentials("guest", "guest")
        .AddQueue("reward-queue")                   // 보상 지급 work queue
        .AddQueue("payment-queue")                  // 결제 처리 work queue
        .AddFanout(                                 // 운영 공지 브로드캐스트
            exchangeName: "ops-announcements",
            boundQueues: ["lobby-fan", "ingame-fan"]))
    .RunAsync();
