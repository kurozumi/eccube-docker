<?php

declare(strict_types=1);

namespace CustomizeMigrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\Migrations\AbstractMigration;

/**
 * dtb_customer に親アカウント（取引先の管理者）への参照を追加する.
 */
final class Version20260805000000 extends AbstractMigration
{
    public function getDescription(): string
    {
        return '取引先の担当者アカウント: dtb_customer.parent_customer_id を追加';
    }

    public function up(Schema $schema): void
    {
        $table = $schema->getTable('dtb_customer');

        if ($table->hasColumn('parent_customer_id')) {
            return;
        }

        $table->addColumn('parent_customer_id', 'integer', [
            'notnull' => false,
            'unsigned' => true,
        ]);
        $table->addIndex(['parent_customer_id'], 'dtb_customer_parent_customer_id_idx');
        $table->addForeignKeyConstraint(
            'dtb_customer',
            ['parent_customer_id'],
            ['id'],
            ['onDelete' => 'SET NULL'],
            'fk_customer_parent_customer'
        );
    }

    public function down(Schema $schema): void
    {
        $table = $schema->getTable('dtb_customer');

        if (!$table->hasColumn('parent_customer_id')) {
            return;
        }

        $table->removeForeignKey('fk_customer_parent_customer');
        $table->dropIndex('dtb_customer_parent_customer_id_idx');
        $table->dropColumn('parent_customer_id');
    }
}
