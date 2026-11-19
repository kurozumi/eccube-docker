<?php

/*
 * eccube-docker が足すもの（EC-CUBE 本体ではない）。
 * 読み込むのは app/config/eccube/packages/schema_rename_guard.php。
 */

namespace EccubeDocker\Schema;

use Doctrine\DBAL\Schema\ComparatorConfig;
use Doctrine\DBAL\Schema\SchemaDiff;
use Doctrine\DBAL\Schema\TableDiff;
use Doctrine\ORM\Mapping as ORM;
use Doctrine\ORM\Tools\SchemaTool;
use Eccube\Service\SchemaService;

/**
 * プラグインの有効化・スキーマ更新で、**別のプラグインの列のデータが失われる**のを止める（4.4）。
 * 止めるものは 2 つ。
 *
 * ## 1. 名前の変更の推測（データが別の列へ移る）
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
 * 列の名前を変えるのはマイグレーションの役目で、スキーマ更新が推測してよいものではない。
 *
 * ## 2. 無効なプラグインの列の削除（データごと消える）
 *
 * 有効なプラグインのスキーマ更新（`eccube:plugin:schema-update`・`eccube:plugin:update`・
 * オーナーズストアの更新）は、**有効なプラグインだけ**から作ったメタデータと DB を比べる
 * （PluginService::generateProxyAndCallback が findAllEnabled でプロキシを作る）。
 * 「追加だけ」の saveMode が外すのはテーブルとシーケンスの削除だけで、**列・索引・外部キーの
 * 削除は残る。** インストール済みで無効のプラグインの列は、メタデータに無いので DROP される。
 *
 * 実際に起きたこと（2026-11-19、37 本インストール・全部無効のデモ本番）: `bin/plugin.sh enable`
 * を 1 本打ち、他のプラグインの列 46 本をデータごと消した。エラーは出ない。消えた側を有効に
 * した時点で、その列を読む画面が Unknown column で落ちる（本体の enable は列を足さない）。
 *
 * そこで saveMode では、**dtb_plugin に載っているプラグインのエンティティが宣言する列**
 * （とその列に掛かる索引・外部キー）を削除から外す。それ以外は本体と同じに消す:
 *   - アンインストール中のプラグインは、本体がスキーマ更新の前に dtb_plugin から外す
 *     （unregisterPlugin が flush する）ので、その列は今までどおり消える
 *   - プラグインの新しい版が宣言から外した列も消える（どのプラグインも宣言していないため）
 *
 * Doctrine のメタデータは有効なプラグインしか知らないので、無効なものはエンティティの
 * 属性をリフレクションで直接読む。
 *
 * **EC-CUBE 4.2 / 4.3 では何もしない**（本体の処理へそのまま渡す）。Doctrine が古く、
 * 名前の変更の推測を止める設定が無い。
 */
class RenameSafeSchemaService extends SchemaService
{
    private ?string $pluginDir = null;

    /**
     * schema_rename_guard.php が `%kernel.project_dir%/app/Plugin` を渡す。
     * コンストラクタに足さないのは、4.2 / 4.3 の本体の引数と食い違わせないため。
     */
    public function setPluginDir(string $pluginDir): void
    {
        $this->pluginDir = $pluginDir;
    }

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
     * 比較器の「名前の変更の推測」を切り、saveMode ではインストール済みのプラグインの列を
     * 削除から外す。
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
            // 読めないエンティティがあったら null（どの列が誰のものか分からない）。
            // そのときは列・索引・外部キーの削除を一切しない。消し損ねた列は残るだけだが、
            // 消してしまった列はデータごと戻らない
            $owned = $this->installedPluginColumns();
            $altered = [];
            foreach ($schemaDiff->getAlteredTables() as $key => $tableDiff) {
                $tableDiff = $this->keepOwnedColumns($tableDiff, $owned);
                if (!$tableDiff->isEmpty()) {
                    $altered[$key] = $tableDiff;
                }
            }

            // 本体と同じく、テーブルとシーケンスの削除は外す
            $schemaDiff = new SchemaDiff(
                $schemaDiff->getCreatedSchemas(),
                $schemaDiff->getDroppedSchemas(),
                $schemaDiff->getCreatedTables(),
                $altered,
                [],
                $schemaDiff->getCreatedSequences(),
                $schemaDiff->getAlteredSequences(),
                [],
            );
        }

        return $connection->getDatabasePlatform()->getAlterSchemaSQL($schemaDiff);
    }

    /**
     * 列・索引・外部キーの削除のうち、インストール済みのプラグインの列に掛かるものを外す。
     *
     * @param array<string, array<string, true>>|null $owned テーブル => 列 => true（小文字）。
     *                                                       null は「分からない」で、削除を全部外す
     */
    private function keepOwnedColumns(TableDiff $diff, ?array $owned): TableDiff
    {
        if (null === $owned) {
            $keepAll = static fn (): bool => true;
        } else {
            $cols = $owned[self::normalize($diff->getOldTable()->getName())] ?? [];
            if ([] === $cols) {
                return $diff;
            }
            $keepAll = static function (array $columns) use ($cols): bool {
                foreach ($columns as $c) {
                    if (isset($cols[self::normalize((string) $c)])) {
                        return true;
                    }
                }

                return false;
            };
        }

        // **同じ名前で足し直す索引・外部キーは外さない。** 定義を変えたときの DBAL の表し方は
        // 「DROP して ADD」で、DROP だけ外すと ADD が「既にある」で落ちる
        $readded = static function (array $assets): array {
            $names = [];
            foreach ($assets as $a) {
                $names[self::normalize($a->getName())] = true;
            }

            return $names;
        };
        $readdedIndexes = $readded($diff->getAddedIndexes());
        $readdedForeignKeys = $readded($diff->getAddedForeignKeys());

        $droppedColumns = array_filter(
            $diff->getDroppedColumns(),
            static fn ($c) => !$keepAll([$c->getName()])
        );
        $droppedIndexes = array_filter(
            $diff->getDroppedIndexes(),
            static fn ($i) => isset($readdedIndexes[self::normalize($i->getName())]) || !$keepAll($i->getColumns())
        );
        $droppedForeignKeys = array_filter(
            $diff->getDroppedForeignKeys(),
            static fn ($fk) => isset($readdedForeignKeys[self::normalize($fk->getName())]) || !$keepAll($fk->getLocalColumns())
        );

        if (count($droppedColumns) === count($diff->getDroppedColumns())
            && count($droppedIndexes) === count($diff->getDroppedIndexes())
            && count($droppedForeignKeys) === count($diff->getDroppedForeignKeys())) {
            return $diff;
        }

        return new TableDiff(
            $diff->getOldTable(),
            $diff->getAddedColumns(),
            $diff->getChangedColumns(),
            $droppedColumns,
            $diff->getAddedIndexes(),
            $diff->getModifiedIndexes(),
            $droppedIndexes,
            $diff->getRenamedIndexes(),
            $diff->getAddedForeignKeys(),
            $diff->getModifiedForeignKeys(),
            $droppedForeignKeys,
        );
    }

    /**
     * dtb_plugin に載っているプラグイン（有効・無効を問わない）のエンティティが宣言する列。
     *
     * @return array<string, array<string, true>>|null テーブル => 列 => true（小文字）。
     *                                                 読めないエンティティがあれば null
     */
    private function installedPluginColumns(): ?array
    {
        if (null === $this->pluginDir) {
            return null;
        }

        $codes = $this->entityManager->getConnection()->fetchFirstColumn('SELECT code FROM dtb_plugin');
        $naming = $this->entityManager->getConfiguration()->getNamingStrategy();

        $attr = static function (\ReflectionClass|\ReflectionProperty $r, string $class): ?array {
            $a = $r->getAttributes($class, \ReflectionAttribute::IS_INSTANCEOF);

            return $a ? $a[0]->getArguments() : null;
        };
        $tableOf = static function (string $class) use ($attr, $naming): string {
            $t = $attr(new \ReflectionClass($class), ORM\Table::class);

            return $t['name'] ?? $t[0] ?? $naming->classToTableName($class);
        };

        $owned = [];
        foreach ($codes as $code) {
            $dir = $this->pluginDir.'/'.$code.'/Entity';
            if (!is_dir($dir)) {
                continue;
            }
            $files = new \RecursiveIteratorIterator(new \RecursiveDirectoryIterator($dir, \FilesystemIterator::SKIP_DOTS));
            foreach ($files as $file) {
                if ('php' !== $file->getExtension()) {
                    continue;
                }
                $class = 'Plugin\\'.$code.'\\Entity\\'.str_replace('/', '\\', substr($file->getPathname(), strlen($dir) + 1, -4));

                // **読めないものがあったら、誰の列か分からないとして null を返す**（呼び出し側が
                // 削除を全部外す）。飛ばすと、そのプラグインの列だけ守られずに消える
                try {
                    if (!class_exists($class) && !trait_exists($class)) {
                        continue;
                    }
                    $r = new \ReflectionClass($class);

                    // EntityExtension は繰り返せる（1 つのトレイトを複数のエンティティへ）
                    $tables = [];
                    foreach ($r->getAttributes() as $a) {
                        if (str_ends_with($a->getName(), '\\EntityExtension')) {
                            $args = $a->getArguments();
                            $tables[] = $tableOf($args[0] ?? $args['value']);
                        }
                    }
                    if ([] === $tables && $r->getAttributes(ORM\Entity::class)) {
                        $tables[] = $tableOf($class);
                    }

                    $columns = [];
                    foreach ($r->getProperties() as $p) {
                        // 親クラスの分は親のテーブル。ただし MappedSuperclass の列は子のテーブルに載る
                        $declaring = $p->getDeclaringClass();
                        if (!$r->isTrait() && $declaring->getName() !== $class
                            && !$declaring->getAttributes(ORM\MappedSuperclass::class)) {
                            continue;
                        }
                        if (null !== ($c = $attr($p, ORM\Column::class))) {
                            $columns[] = $c['name'] ?? $c[0] ?? $naming->propertyToColumnName($p->getName(), $class);
                        }
                        if ($p->getAttributes(ORM\ManyToOne::class) || $p->getAttributes(ORM\OneToOne::class)) {
                            // 複合キーの関連は JoinColumn を複数並べる
                            $joins = $p->getAttributes(ORM\JoinColumn::class, \ReflectionAttribute::IS_INSTANCEOF);
                            if ([] === $joins) {
                                $columns[] = $naming->joinColumnName($p->getName(), $class);
                            }
                            foreach ($joins as $j) {
                                $args = $j->getArguments();
                                $columns[] = $args['name'] ?? $args[0] ?? $naming->joinColumnName($p->getName(), $class);
                            }
                        }
                    }

                    foreach ($tables as $table) {
                        foreach ($columns as $column) {
                            $owned[self::normalize($table)][self::normalize($column)] = true;
                        }
                    }
                } catch (\Throwable) {
                    return null;
                }
            }
        }

        return $owned;
    }

    private static function normalize(string $name): string
    {
        return strtolower(trim($name, '`"[]'));
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
