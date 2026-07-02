using Confluent.Kafka;
using Confluent.Kafka.Admin;
using RabbitMQ.Client;

namespace BrokerInitializer;

/// <summary>
/// Kafka 토픽과 RabbitMQ 큐/exchange를 초기화하는 도구.
/// 테스트 전 브로커 상태를 깨끗하게 리셋하는 용도로 쓴다.
///
/// 주의: 이 도구는 기존 토픽/큐를 삭제하고 재생성한다.
///       잘못 실행하면 운영 데이터가 사라질 수 있으므로
///       반드시 개발/테스트 환경에서만 실행한다.
/// </summary>
public sealed class BrokerInitializer
{
    private Action<KafkaConfig>? _kafkaSetup;
    private Action<RabbitMqConfig>? _rabbitSetup;

    private BrokerInitializer() { }

    /// <summary>초기화 빌더를 시작한다.</summary>
    public static BrokerInitializer Create() => new();

    /// <summary>Kafka 설정을 구성한다.</summary>
    public BrokerInitializer Kafka(Action<KafkaConfig> setup)
    {
        _kafkaSetup = setup;
        return this;
    }

    /// <summary>RabbitMQ 설정을 구성한다.</summary>
    public BrokerInitializer RabbitMQ(Action<RabbitMqConfig> setup)
    {
        _rabbitSetup = setup;
        return this;
    }

    /// <summary>설정에 따라 Kafka와 RabbitMQ를 초기화한다.</summary>
    public async Task RunAsync()
    {
        Console.WriteLine("=== BrokerInitializer 시작 ===");
        Console.WriteLine();

        if (_kafkaSetup is not null)
        {
            var config = new KafkaConfig();
            _kafkaSetup(config);
            await InitKafkaAsync(config);
        }

        if (_rabbitSetup is not null)
        {
            var config = new RabbitMqConfig();
            _rabbitSetup(config);
            InitRabbitMq(config);
        }

        Console.WriteLine();
        Console.WriteLine("=== 초기화 완료 ===");
    }

    private static async Task InitKafkaAsync(KafkaConfig config)
    {
        Console.WriteLine($"[Kafka] {config.BootstrapServers} 연결 중...");

        var adminConfig = new AdminClientConfig { BootstrapServers = config.BootstrapServers };
        using var admin = new AdminClientBuilder(adminConfig).Build();

        // 기존 토픽 목록 조회
        var metadata = admin.GetMetadata(TimeSpan.FromSeconds(10));
        var existingTopics = metadata.Topics.Select(t => t.Topic).ToHashSet();

        // 이미 있는 토픽 삭제
        var toDelete = config.Topics
            .Select(t => t.Name)
            .Where(existingTopics.Contains)
            .ToList();

        if (toDelete.Count > 0)
        {
            Console.WriteLine($"[Kafka] 기존 토픽 삭제: {string.Join(", ", toDelete)}");
            await admin.DeleteTopicsAsync(toDelete);
            // 삭제 후 브로커가 반영할 시간을 잠깐 준다
            await Task.Delay(TimeSpan.FromSeconds(2));
        }

        // 토픽 생성
        if (config.Topics.Count > 0)
        {
            var specs = config.Topics.Select(t => new TopicSpecification
            {
                Name = t.Name,
                NumPartitions = t.Partitions,
                ReplicationFactor = t.ReplicationFactor,
            }).ToList();

            await admin.CreateTopicsAsync(specs);

            foreach (var t in config.Topics)
            {
                Console.WriteLine($"[Kafka] 토픽 생성: {t.Name} (파티션={t.Partitions}, 복제본={t.ReplicationFactor})");
            }
        }
    }

    private static void InitRabbitMq(RabbitMqConfig config)
    {
        Console.WriteLine($"[RabbitMQ] {config.Host}:{config.Port} 연결 중...");

        var factory = new ConnectionFactory
        {
            HostName = config.Host,
            Port = config.Port,
            UserName = config.UserName,
            Password = config.Password,
            VirtualHost = config.VirtualHost,
        };

        using var connection = factory.CreateConnection();
        using var channel = connection.CreateModel();

        // fanout exchange 삭제 후 재생성
        foreach (var fanout in config.Fanouts)
        {
            // 바인딩된 큐 먼저 삭제
            foreach (var queueName in fanout.BoundQueues)
            {
                channel.QueueDelete(queueName, ifUnused: false, ifEmpty: false);
                Console.WriteLine($"[RabbitMQ] 큐 삭제: {queueName}");
            }

            // exchange 삭제
            channel.ExchangeDelete(fanout.ExchangeName, ifUnused: false);
            Console.WriteLine($"[RabbitMQ] Exchange 삭제: {fanout.ExchangeName}");

            // exchange 재생성
            channel.ExchangeDeclare(fanout.ExchangeName, ExchangeType.Fanout, durable: true);
            Console.WriteLine($"[RabbitMQ] Fanout exchange 생성: {fanout.ExchangeName}");

            // 큐 재생성 + 바인딩
            foreach (var queueName in fanout.BoundQueues)
            {
                channel.QueueDeclare(queueName, durable: true, exclusive: false, autoDelete: false);
                channel.QueueBind(queueName, fanout.ExchangeName, routingKey: string.Empty);
                Console.WriteLine($"[RabbitMQ]   └ 큐 생성 + 바인딩: {queueName} → {fanout.ExchangeName}");
            }
        }

        // work queue 패턴 큐 삭제 후 재생성
        foreach (var queue in config.Queues)
        {
            channel.QueueDelete(queue.Name, ifUnused: false, ifEmpty: false);
            Console.WriteLine($"[RabbitMQ] 큐 삭제: {queue.Name}");

            channel.QueueDeclare(queue.Name, durable: true, exclusive: false, autoDelete: false);
            Console.WriteLine($"[RabbitMQ] 큐 생성: {queue.Name}");
        }
    }
}
