<?php

/*
 * セッションを Redis に載せたとき（optional/redis/redis_session.yaml）、EC-CUBE 4.2 / 4.3 では本体の
 * SameSiteNoneCompatSessionHandler で包み直す。
 *
 * **4.2 / 4.3 の本体は、セッションの Cookie の属性をこのハンドラで決めている**（SameSite=None・Secure・
 * ECCUBE_COOKIE_PATH）。redis_session.yaml が handler_id を生の Redis ハンドラへ差し替えると誰も付けず、
 * SameSite はブラウザの既定（Lax）になる。**決済の戻り（よそのサイトからの POST）でセッションが届かず、
 * 注文の途中でカートやログインが消える。** 4.4 ではこのクラスが無く、本体も素のファイルのハンドラ（Lax）なので、
 * 包まない（同じ振る舞いのまま）。
 *
 * **packages/ に置き、Redis のセッションが入っているときだけ効かせる。** optional/ の中身は entrypoint が
 * *.yaml だけを packages/ へ写すので、ここで redis_session.yaml があるかを見る。handler_id を後から上書きすると
 * 読む順番（php と yaml のどちらが後か）に左右されるので、Redis のハンドラを飾る（decorate）形にする。
 */

use Symfony\Component\DependencyInjection\ContainerInterface;
use Symfony\Component\DependencyInjection\Loader\Configurator\ContainerConfigurator;

use function Symfony\Component\DependencyInjection\Loader\Configurator\service;

return static function (ContainerConfigurator $container): void {
    $compat = 'Eccube\Session\Storage\Handler\SameSiteNoneCompatSessionHandler';
    if (!is_file(__DIR__.'/redis_session.yaml') || !class_exists($compat)) {
        return;
    }
    $container->services()
        ->set('eccube_docker.redis_session_samesite', $compat)
        ->decorate('Customize\Session\RawRedisSessionHandler', null, 0, ContainerInterface::IGNORE_ON_INVALID_REFERENCE)
        ->args([service('.inner')]);
};
