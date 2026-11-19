<?php

/*
 * プラグインの有効化で、別のプラグインの列のデータが入れ替わるのを止める。
 * 理由と中身は lib/RenameSafeSchemaService.php。
 *
 * **クラスは lib/ に置き、ここで読み込む。** app/Customize は利用者のもので、
 * bin/self-update.sh が届けられない。app/config/eccube/packages は届けられる。
 * lib/ のような下のディレクトリは、本体の Kernel が設定として読まない
 * （読むのは packages/*.{php,yaml} と packages/<環境>/ だけ）。
 *
 * コンテナを組み立てるとき（ここ）と、組み立て済みのコンテナが使うとき（file）の
 * 両方で読み込む。組み立て済みのコンテナはこの設定ファイルを読まないので、
 * file が無いとクラスが見つからず全ページ 500 になる。
 */

use Symfony\Component\DependencyInjection\Loader\Configurator\ContainerConfigurator;

require_once __DIR__.'/lib/RenameSafeSchemaService.php';

return static function (ContainerConfigurator $container): void {
    $container->services()
        ->set('eccube_docker.rename_safe_schema_service', \EccubeDocker\Schema\RenameSafeSchemaService::class)
        ->decorate(\Eccube\Service\SchemaService::class)
        ->file('%kernel.project_dir%/app/config/eccube/packages/lib/RenameSafeSchemaService.php')
        ->autowire();
};
