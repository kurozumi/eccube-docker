<?php

namespace Customize\Repository\QueryCustomizer;

use Doctrine\ORM\QueryBuilder;
use Eccube\Doctrine\Query\QueryCustomizer;
use Eccube\Entity\Customer;
use Eccube\Repository\QueryKey;

/**
 * 取引先の管理者がマイページを開いたとき、担当者アカウントの受注も一覧に含める.
 */
class CompanyOrderCustomizer implements QueryCustomizer
{
    /**
     * @param array<string, mixed> $params
     */
    public function customize(QueryBuilder $builder, array $params, string $queryKey): void
    {
        $Customer = $params['customer'] ?? null;

        if (!$Customer instanceof Customer || !$Customer->isCompanyAdmin()) {
            return;
        }

        $Members = $Customer->getActiveCompanyMembers();
        if ($Members->isEmpty()) {
            return;
        }

        // 元の条件（o.Customer = :Customer）は残したまま担当者分を足す.
        // :Customer を使わなくすると、未使用パラメータで Doctrine が例外を投げる.
        $builder
            ->orWhere($builder->expr()->in('o.Customer', ':CompanyMembers'))
            ->setParameter('CompanyMembers', $Members);
    }

    public function getQueryKey(): string
    {
        return QueryKey::ORDER_SEARCH_BY_CUSTOMER;
    }
}
