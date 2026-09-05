<?php
/*
 * 初期管理者が既定の admin / password のままかを DB で確かめる（#108）。
 * bin/publish.sh が本番公開の前に呼ぶ。出力は 1 語:
 *   DEFAULT … login_id=admin が "password" で通る（公開してはいけない）
 *   OK      … 通らない
 *   SKIP    … 判定できない（未インストール、テーブル無し、クラス無し）
 * .env の ECCUBE_ADMIN_PASS は fixtures を入れる瞬間にしか効かないので、
 * 「いまの DB」を見るのが唯一確かな方法。
 */
$root = '/var/www/html';
if (!is_file("$root/vendor/autoload.php") || !is_file("$root/var/.eccube_installed")) { echo "SKIP\n"; exit(0); }
require "$root/vendor/autoload.php";
(new Symfony\Component\Dotenv\Dotenv())->bootEnv("$root/.env");
try {
    $kernel = new Eccube\Kernel($_SERVER['APP_ENV'] ?? 'prod', false);
    $kernel->boot();
    $c = $kernel->getContainer();
    $em = $c->get('doctrine')->getManager();
    $member = $em->getRepository(Eccube\Entity\Member::class)->findOneBy(['login_id' => 'admin']);
    if (!$member) { echo "OK\n"; exit(0); }   // admin という名前の管理者がいない
    // 4.4 は Symfony の native hasher（bcrypt / argon。salt 無し）、4.2 / 4.3 は HMAC（salt あり）。
    // 4.4 でも古いバージョンから上げた管理者は HMAC のまま残るので、格納形式で見分ける。
    // ハッシュ器はコンテナでは private なので、HMAC のほうはパラメータから自分で組み立てる。
    $stored = $member->getPassword();
    if (preg_match('/^\$(2[aby]|argon2)/', $stored)) {
        $ok = password_verify('password', $stored);
    } elseif (class_exists(Eccube\Security\PasswordHasher\PasswordHasher::class)) {          // 4.2〜
        $h = new Eccube\Security\PasswordHasher\PasswordHasher(
            (string) $c->getParameter('eccube_auth_magic'),
            (string) $c->getParameter('eccube_auth_type'),
            (string) $c->getParameter('eccube_password_hash_algos'),
        );
        $ok = $h->verify($stored, 'password', $member->getSalt());
    } elseif (class_exists(Eccube\Security\Core\Encoder\PasswordEncoder::class)) {   // 4.0 / 4.1
        $h = new Eccube\Security\Core\Encoder\PasswordEncoder(new Eccube\Common\EccubeConfig($c));
        $ok = $h->isPasswordValid($stored, 'password', $member->getSalt());
    } else { echo "SKIP\n"; exit(0); }
    echo $ok ? "DEFAULT\n" : "OK\n";
} catch (Throwable $e) {
    echo "SKIP\n";
}
