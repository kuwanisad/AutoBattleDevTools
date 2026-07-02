namespace BrokerInitializer;

/// <summary>RabbitMQ 초기화 설정을 빌더 패턴으로 구성한다.</summary>
public sealed class RabbitMqConfig
{
    public string Host { get; private set; } = "localhost";
    public int Port { get; private set; } = 5672;
    public string UserName { get; private set; } = "guest";
    public string Password { get; private set; } = "guest";
    public string VirtualHost { get; private set; } = "/";

    public IReadOnlyList<QueueSpec> Queues => _queues;
    public IReadOnlyList<FanoutSpec> Fanouts => _fanouts;

    private readonly List<QueueSpec> _queues = new();
    private readonly List<FanoutSpec> _fanouts = new();

    public RabbitMqConfig Server(string host, int port = 5672)
    {
        Host = host;
        Port = port;
        return this;
    }

    public RabbitMqConfig Credentials(string userName, string password)
    {
        UserName = userName;
        Password = password;
        return this;
    }

    /// <summary>
    /// work queue 패턴용 큐를 추가한다.
    /// 이미 존재하면 메시지를 비운다 (purge).
    /// </summary>
    public RabbitMqConfig AddQueue(string name)
    {
        _queues.Add(new QueueSpec(name));
        return this;
    }

    /// <summary>
    /// fanout exchange와 거기 바인딩할 큐들을 추가한다.
    /// 운영 공지처럼 모든 구독자에게 브로드캐스트해야 하는 경우에 쓴다.
    /// </summary>
    public RabbitMqConfig AddFanout(string exchangeName, params string[] boundQueues)
    {
        _fanouts.Add(new FanoutSpec(exchangeName, boundQueues));
        return this;
    }

    public sealed record QueueSpec(string Name);
    public sealed record FanoutSpec(string ExchangeName, IReadOnlyList<string> BoundQueues);
}
