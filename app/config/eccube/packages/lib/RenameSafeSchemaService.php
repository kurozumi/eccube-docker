<?php

/*
 * eccube-docker が足すもの（EC-CUBE 本体ではない）。
 * 読み込むのは app/config/eccube/packages/schema_rename_guard.php。
 */

namespace EccubeDocker\Schema;

use Doctrine\DBAL\Schema\ComparatorConfig;
use Doctrine\DBAL\Schema\SchemaDiff;
use Doctrine\ORM\Tools\SchemaTool;
use Eccube\Service\SchemaService;

/**
 * プラグインの有効化で、**別のプラグインの列のデータが入れ替わる**のを止める。
 *
 * EC-CUBE 4.4 の SchemaService::updateSchema は Doctrine DBAL 4 の比較器を既定のまま
 * 使う。既定では「列の名前が変わった」を推測する。同じテーブルで
 *
 *   - 無効にしたプラグインの列が消える（メタデータから外れたので「削除」）
 *   - 有効にするプラグインの列が増える（「追加」）
 *
 * が同時に起き、型が同じだと、削除と追加の組を**名前の変更**とみなし、
 * `ALTER TABLE ... CHANGE 古い列 新しい列` を打つ。**データはそのまま新しい列へ移る。**
 *
 * 実際に起きたこと: 取引先アカウント管理（B2BCompany）を無効にして営業担当者（B2BSalesRep）を
 * 有効にしたら、会員の「所属する取引先」の ID が「担当営業」の ID の列へ移った。
 * 番号が営業担当者として無かったので外部キーで止まったが、**番号が重なれば止まらず、
 * 会員に別の担当営業が付く。** 所属する取引先も失われる。
 *
 * ここでは名前の変更の推測だけを止める（削除と追加として扱う）。それ以外は本体と同じ。
 * 列の名前を変えるのはマイグレーションの役目で、スキーマ更新が推測してよいものではない。
 *
 * **EC-CUBE 4.2 / 4.3 では何もしない**（本体の処理へそのまま渡す）。Doctrine が古く、
 * この推測を止める設定が無い。
 */
class RenameSafeSchemaService extends SchemaService
{
    /**
     * 引数に型を書かない。4.2 / 4.3 の本体は型の無い宣言なので、型を書くと
     * そちらで読み込んだ瞬間に互換エラーになる。
     */
    public function updateSchema($generatedFiles, $proxiesDirectory, $saveMode = false): void
    {
        if (!self::isSupported()) {
            parent::updateSchema($generatedFiles, $proxiesDirectory, $saveMode);

            return;
        }

        $connection = $this->entityManager->getConnection();

        // 本体の全同期（saveMode = false）は、比較元の絞り込み（schemaAssetsFilter）が
        // 設定されていると比較元の作り方が変わる。EC-CUBE は設定しないが、されていたら
        // 本体へ任せる（ここで作り方を写し間違えるほうが怖い）
        if (!$saveMode && null !== $connection->getConfiguration()->getSchemaAssetsFilter()) {
            parent::updateSchema($generatedFiles, $proxiesDirectory, $saveMode);

            return;
        }

        $this->executeCallback(function (SchemaTool $tool, array $metaData) use ($saveMode, $connection): void {
            foreach ($this->buildUpdateSql($tool, $metaData, (bool) $saveMode) as $sql) {
                $connection->executeStatement($sql);
            }
        }, $generatedFiles, $proxiesDirectory);
    }

    /**
     * 打つ SQL を作る（打たない）。本体の updateSchema と同じ組み立てで、
     * 比較器の「名前の変更の推測」だけを切る。
     *
     * @param array<mixed> $metaData
     *
     * @return list<string>
     */
    public function buildUpdateSql(SchemaTool $tool, array $metaData, bool $saveMode): array
    {
        $connection = $this->entityManager->getConnection();
        $schemaManager = $connection->createSchemaManager();

        $toSchema = $tool->getSchemaFromMetadata($metaData);
        $fromSchema = $schemaManager->introspectSchema();
        $comparator = $schemaManager->createComparator(
            (new ComparatorConfig())
                ->withReportModifiedIndexes(false)
                ->withDetectRenamedColumns(false)
        );
        $schemaDiff = $comparator->compareSchemas($fromSchema, $toSchema);

        if ($saveMode) {
            // 本体と同じく、テーブルとシーケンスの削除だけを外す
            $schemaDiff = new SchemaDiff(
                $schemaDiff->getCreatedSchemas(),
                $schemaDiff->getDroppedSchemas(),
                $schemaDiff->getCreatedTables(),
                $schemaDiff->getAlteredTables(),
                [],
                $schemaDiff->getCreatedSequences(),
                $schemaDiff->getAlteredSequences(),
                [],
            );
        }

        return $connection->getDatabasePlatform()->getAlterSchemaSQL($schemaDiff);
    }

    /**
     * 名前の変更の推測を切れる Doctrine か（DBAL 4.3 以降）。
     */
    public static function isSupported(): bool
    {
        return class_exists(ComparatorConfig::class)
            && method_exists(ComparatorConfig::class, 'withDetectRenamedColumns')
            && class_exists(SchemaDiff::class)
            && method_exists(SchemaDiff::class, 'getAlteredTables');
    }
}
