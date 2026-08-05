<?php

namespace Customize\Controller\Mypage;

use Customize\Form\Type\Front\CompanyMemberType;
use Eccube\Controller\AbstractController;
use Eccube\Entity\Customer;
use Eccube\Entity\Master\CustomerStatus;
use Eccube\Repository\CustomerRepository;
use Eccube\Repository\Master\CustomerStatusRepository;
use Eccube\Util\StringUtil;
use Symfony\Bridge\Twig\Attribute\Template;
use Symfony\Component\HttpFoundation\RedirectResponse;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpKernel\Exception\AccessDeniedHttpException;
use Symfony\Component\HttpKernel\Exception\NotFoundHttpException;
use Symfony\Component\PasswordHasher\Hasher\UserPasswordHasherInterface;
use Symfony\Component\Routing\Attribute\Route;

/**
 * 取引先の担当者アカウント管理.
 */
class CompanyMemberController extends AbstractController
{
    public function __construct(
        private readonly CustomerRepository $customerRepository,
        private readonly CustomerStatusRepository $customerStatusRepository,
        private readonly UserPasswordHasherInterface $passwordHasher,
    ) {
    }

    /**
     * 担当者アカウントの一覧.
     *
     * @return array<string, mixed>
     */
    #[Route(path: '/mypage/company/members', name: 'mypage_company_member', methods: ['GET'])]
    #[Template(template: 'Mypage/company_member.twig')]
    public function index(): array
    {
        $Owner = $this->getCompanyAdmin();

        return [
            'Owner' => $Owner,
            'Members' => $Owner->getActiveCompanyMembers(),
        ];
    }

    /**
     * 担当者アカウントを追加する.
     *
     * @return RedirectResponse|array<string, mixed>
     */
    #[Route(path: '/mypage/company/members/new', name: 'mypage_company_member_new', methods: ['GET', 'POST'])]
    #[Template(template: 'Mypage/company_member_edit.twig')]
    public function new(Request $request): RedirectResponse|array
    {
        $Owner = $this->getCompanyAdmin();

        /** @var Customer $Member */
        $Member = $this->customerRepository->newCustomer();
        $this->inheritFromOwner($Member, $Owner);

        $form = $this->formFactory->create(CompanyMemberType::class, $Member);
        $form->handleRequest($request);

        if ($form->isSubmitted() && $form->isValid()) {
            // 管理者が登録するアカウントなので、仮会員を経由せず本会員にする.
            $Member->setStatus($this->customerStatusRepository->find(CustomerStatus::REGULAR));
            $Member->setPassword(
                $this->passwordHasher->hashPassword($Member, $Member->getPlainPassword())
            );

            $this->entityManager->persist($Member);
            $this->entityManager->flush();

            $this->addSuccess('担当者アカウントを登録しました。');

            return $this->redirectToRoute('mypage_company_member');
        }

        return [
            'form' => $form->createView(),
            'Owner' => $Owner,
        ];
    }

    /**
     * 担当者アカウントを退会させる.
     */
    #[Route(path: '/mypage/company/members/{id}/withdraw', name: 'mypage_company_member_withdraw', methods: ['DELETE'], requirements: ['id' => '\d+'])]
    public function withdraw(int $id): RedirectResponse
    {
        $this->isTokenValid();

        $Owner = $this->getCompanyAdmin();

        $Member = $this->customerRepository->find($id);
        if (null === $Member || $Member->getCompanyOwner() !== $Owner) {
            throw new NotFoundHttpException();
        }

        // 本体の退会と同じく、ステータスを退会にしてメールアドレスを解放する.
        $Member->setStatus($this->customerStatusRepository->find(CustomerStatus::WITHDRAWING));
        $Member->setEmail(StringUtil::random(60).'@dummy.dummy');

        $this->entityManager->flush();

        $this->addSuccess('担当者アカウントを削除しました。');

        return $this->redirectToRoute('mypage_company_member');
    }

    /**
     * 会社の情報を担当者へ引き継ぐ.
     */
    private function inheritFromOwner(Customer $Member, Customer $Owner): void
    {
        $Member
            ->setCompanyOwner($Owner)
            ->setCompanyName($Owner->getCompanyName())
            ->setPostalCode($Owner->getPostalCode())
            ->setPref($Owner->getPref())
            ->setAddr01($Owner->getAddr01())
            ->setAddr02($Owner->getAddr02());

        // 会員グループ管理プラグインを入れているときは、卸価格の根拠になる会員グループも引き継ぐ.
        if (method_exists($Owner, 'getGroups') && method_exists($Member, 'addGroup')) {
            foreach ($Owner->getGroups() as $Group) {
                $Member->addGroup($Group);
            }
        }
    }

    private function getCompanyAdmin(): Customer
    {
        $Customer = $this->getUser();

        if (!$Customer instanceof Customer || !$Customer->isCompanyAdmin()) {
            throw new AccessDeniedHttpException();
        }

        return $Customer;
    }
}
