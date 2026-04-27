namespace M365Permissions.Engine.Graph;

/// <summary>
/// Manages adaptive concurrency for API calls.
/// Decreases parallelism on 429 throttle responses, slowly increases when no throttling occurs.
/// Exposes metrics for GUI display.
/// </summary>
public sealed class AdaptiveThrottleManager
{
    private SemaphoreSlim _throttle;
    private int _currentMaxConcurrency;
    private readonly int _initialMax;
    private readonly int _absoluteMin = 1;
    private readonly int _absoluteMax;
    private readonly object _lock = new();

    private int _throttleCount;
    private long _totalRequests;
    private DateTimeOffset _lastThrottleTime = DateTimeOffset.MinValue;
    private DateTimeOffset _lastIncreaseTime = DateTimeOffset.UtcNow;
    private DateTimeOffset _firstRequestTime = DateTimeOffset.MinValue;
    private int _requestsSinceLastThrottle;
    private const int RequestsBeforeIncrease = 20;

    public int CurrentConcurrency => _currentMaxConcurrency;
    public int ThrottleCount => _throttleCount;
    public long TotalRequests => Interlocked.Read(ref _totalRequests);
    public DateTimeOffset? LastThrottleTime => _throttleCount > 0 ? _lastThrottleTime : null;

    public AdaptiveThrottleManager(int initialConcurrency, int maxConcurrency)
    {
        _initialMax = initialConcurrency;
        _absoluteMax = maxConcurrency;
        _currentMaxConcurrency = initialConcurrency;
        _throttle = new SemaphoreSlim(initialConcurrency, maxConcurrency);
    }

    public async Task WaitAsync(CancellationToken ct) => await _throttle.WaitAsync(ct);

    public void Release()
    {
        try { _throttle.Release(); } catch (SemaphoreFullException) { /* ignore */ }
    }

    /// <summary>Record that a request was made. Call before executing each API call.</summary>
    public void RecordRequest()
    {
        Interlocked.Increment(ref _totalRequests);
        if (_firstRequestTime == DateTimeOffset.MinValue)
            _firstRequestTime = DateTimeOffset.UtcNow;
    }

    /// <summary>Report a successful request. May increase concurrency if no recent throttling.</summary>
    public void ReportSuccess()
    {
        lock (_lock)
        {
            _requestsSinceLastThrottle++;

            // Only increase if we've had enough successful requests and enough time has passed
            if (_requestsSinceLastThrottle >= RequestsBeforeIncrease
                && _currentMaxConcurrency < _absoluteMax
                && (DateTimeOffset.UtcNow - _lastIncreaseTime).TotalSeconds >= 30)
            {
                _currentMaxConcurrency = Math.Min(_currentMaxConcurrency + 1, _absoluteMax);
                // Release an extra slot to increase effective concurrency
                try { _throttle.Release(); } catch (SemaphoreFullException) { /* at max */ }
                _lastIncreaseTime = DateTimeOffset.UtcNow;
                _requestsSinceLastThrottle = 0;
            }
        }
    }

    /// <summary>Report a 429 throttle response. Immediately decreases concurrency.</summary>
    public void ReportThrottle()
    {
        lock (_lock)
        {
            _throttleCount++;
            _lastThrottleTime = DateTimeOffset.UtcNow;
            _requestsSinceLastThrottle = 0;

            // Halve concurrency (minimum 1)
            var newMax = Math.Max(_absoluteMin, _currentMaxConcurrency / 2);
            if (newMax < _currentMaxConcurrency)
            {
                _currentMaxConcurrency = newMax;
                // We can't remove slots from SemaphoreSlim, but we limit by not releasing
                // The effective limit happens naturally as existing WaitAsync calls won't release extra slots
            }
        }
    }

    /// <summary>Get current metrics for GUI display.</summary>
    public ThrottleMetrics GetMetrics()
    {
        var total = Interlocked.Read(ref _totalRequests);
        var elapsed = _firstRequestTime != DateTimeOffset.MinValue
            ? (DateTimeOffset.UtcNow - _firstRequestTime).TotalSeconds
            : 0;
        var rps = elapsed > 0 ? total / elapsed : 0;

        return new()
        {
            CurrentConcurrency = _currentMaxConcurrency,
            MaxConcurrency = _absoluteMax,
            TotalRequests = total,
            ThrottledRequests = _throttleCount,
            RequestsPerSecond = Math.Round(rps, 1),
            LastThrottleTime = _throttleCount > 0 ? _lastThrottleTime.ToString("O") : null
        };
    }
}

public sealed class ThrottleMetrics
{
    public int CurrentConcurrency { get; set; }
    public int MaxConcurrency { get; set; }
    public long TotalRequests { get; set; }
    public int ThrottledRequests { get; set; }
    public double RequestsPerSecond { get; set; }
    public string? LastThrottleTime { get; set; }
}
