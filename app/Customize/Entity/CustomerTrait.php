<?php

namespace Customize\Entity;

use Doctrine\Common\Collections\ArrayCollection;
use Doctrine\Common\Collections\Collection;
use Doctrine\ORM\Mapping as ORM;
use Eccube\Attribute\EntityExtension;
use Eccube\Entity\Customer;
use Eccube\Entity\Master\CustomerStatus;

/**
 * 取引先の担当者アカウント.
 *
 * 会員に親子関係を持たせ、親（取引先の管理者）が子（担当者）を作れるようにする。
 */
#[EntityExtension(Customer::class)]
trait CustomerTrait
{
    /**
     * 親アカウント（取引先の管理者）. 管理者自身は null.
     */
    #[ORM\ManyToOne(targetEntity: Customer::class, inversedBy: 'CompanyMembers')]
    #[ORM\JoinColumn(name: 'parent_customer_id', referencedColumnName: 'id', nullable: true, onDelete: 'SET NULL')]
    private ?Customer $CompanyOwner = null;

    /**
     * この会員がぶら下げている担当者アカウント.
     *
     * @var Collection<int, Customer>|null
     */
    #[ORM\OneToMany(mappedBy: 'CompanyOwner', targetEntity: Customer::class)]
    #[ORM\OrderBy(['id' => 'ASC'])]
    private $CompanyMembers;

    public function getCompanyOwner(): ?Customer
    {
        return $this->CompanyOwner;
    }

    public function setCompanyOwner(?Customer $CompanyOwner): self
    {
        $this->CompanyOwner = $CompanyOwner;

        return $this;
    }

    /**
     * @return Collection<int, Customer>
     */
    public function getCompanyMembers(): Collection
    {
        if (null === $this->CompanyMembers) {
            $this->CompanyMembers = new ArrayCollection();
        }

        return $this->CompanyMembers;
    }

    /**
     * 退会していない担当者アカウント.
     *
     * @return Collection<int, Customer>
     */
    public function getActiveCompanyMembers(): Collection
    {
        return $this->getCompanyMembers()->filter(
            fn (Customer $Member) => CustomerStatus::WITHDRAWING != $Member->getStatus()?->getId()
        );
    }

    /**
     * 取引先の管理者か.
     *
     * 会員グループ管理プラグインを入れているときは、グループに所属している会員だけを
     * 管理者として扱う。入れていないときは、親を持たない会員すべてが管理者になる。
     */
    public function isCompanyAdmin(): bool
    {
        if (null !== $this->CompanyOwner) {
            return false;
        }

        if (method_exists($this, 'getGroups')) {
            return $this->getGroups()->count() > 0;
        }

        return true;
    }

    /**
     * 自社の会員（管理者 + 担当者）.
     *
     * @return array<int, Customer>
     */
    public function getCompanyCustomers(): array
    {
        /** @var Customer $Owner */
        $Owner = $this->CompanyOwner ?? $this;

        return array_merge([$Owner], $Owner->getActiveCompanyMembers()->toArray());
    }
}
