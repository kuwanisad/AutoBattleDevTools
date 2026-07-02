namespace BrokerInitializer;

/// <summary>Kafka 초기화 설정을 빌더 패턴으로 구성한다.</summary>
public sealed class KafkaConfig
{
    public string BootstrapServers { get; private set; } = "localhost:9092";
    public IReadOnlyList<TopicSpec> Topics => _topics;

    private readonly List<TopicSpec> _topics = new();

    public KafkaConfig Server(string bootstrapServers)
    {
        BootstrapServers = bootstrapServers;
        return this;
    }

    /// <summary>
    /// 생성/재생성할 토픽을 추가한다.
    /// 이미 존재하면 삭제 후 재생성한다 (테스트 환경 오염 방지).
    /// </summary>
    public KafkaConfig AddTopic(string name, int partitions = 1, short replicationFactor = 1)
    {
        _topics.Add(new TopicSpec(name, partitions, replicationFactor));
        return this;
    }

    public sealed record TopicSpec(string Name, int Partitions, short ReplicationFactor);
}
