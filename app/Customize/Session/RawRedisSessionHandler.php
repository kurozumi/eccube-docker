<?php

namespace Customize\Session;

/**
 * 生の Redis セッションハンドラ。
 *
 * EC-CUBE 本体の {@see \Eccube\Session\Storage\Handler\SameSiteNoneCompatSessionHandler}
 * は StrictSessionHandler を継承し「内側の生ハンドラ」を包む設計になっている。
 * Symfony の RedisSessionHandler は SessionUpdateTimestampHandlerInterface を実装済みで
 * 二重ラップできない（例外になる）ため、その内側に差し込める「生の」ハンドラをここで用意する。
 *
 * 失効は Redis の TTL（= session.gc_maxlifetime）に任せるので gc() は何もしない。
 * ロックは行わない（Symfony の RedisSessionHandler も既定は非ロック）。
 */
class RawRedisSessionHandler implements \SessionHandlerInterface
{
    /** @var \Redis */
    private $redis;

    /** @var string */
    private $prefix;

    public function __construct(\Redis $redis, string $prefix = 'ecses:')
    {
        $this->redis = $redis;
        $this->prefix = $prefix;
    }

    #[\ReturnTypeWillChange]
    public function open($savePath, $sessionName): bool
    {
        return true;
    }

    #[\ReturnTypeWillChange]
    public function close(): bool
    {
        return true;
    }

    #[\ReturnTypeWillChange]
    public function read($sessionId): string
    {
        $data = $this->redis->get($this->prefix.$sessionId);

        return false === $data ? '' : (string) $data;
    }

    #[\ReturnTypeWillChange]
    public function write($sessionId, $data): bool
    {
        $ttl = (int) ini_get('session.gc_maxlifetime');
        if ($ttl <= 0) {
            $ttl = 1440;
        }

        return (bool) $this->redis->setex($this->prefix.$sessionId, $ttl, $data);
    }

    #[\ReturnTypeWillChange]
    public function destroy($sessionId): bool
    {
        $this->redis->del($this->prefix.$sessionId);

        return true;
    }

    #[\ReturnTypeWillChange]
    public function gc($maxlifetime): int
    {
        // Redis の TTL で自動失効するため何もしない
        return 0;
    }
}
