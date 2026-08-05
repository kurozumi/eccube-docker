<?php

namespace Customize\EventListener;

use Eccube\Entity\Customer;
use Eccube\Event\EccubeEvents;
use Eccube\Event\EventArgs;
use Eccube\Repository\OrderRepository;
use Symfony\Bundle\SecurityBundle\Security;
use Symfony\Component\EventDispatcher\EventSubscriberInterface;

/**
 * 受注履歴の詳細画面で、担当者アカウントの受注も管理者に見せる.
 *
 * MypageController::history() は findOneBy(['Customer' => ログイン会員]) で受注を引くため、
 * 一覧のクエリカスタマイザだけでは詳細が 404 になる。本体が受注を取れなかったときに
 * このイベントで引き直す。
 */
class CompanyOrderHistorySubscriber implements EventSubscriberInterface
{
    public function __construct(
        private readonly OrderRepository $orderRepository,
        private readonly Security $security,
    ) {
    }

    /**
     * @return array<string, string>
     */
    public static function getSubscribedEvents(): array
    {
        return [
            EccubeEvents::FRONT_MYPAGE_MYPAGE_HISTORY_INITIALIZE => 'onHistoryInitialize',
        ];
    }

    public function onHistoryInitialize(EventArgs $event): void
    {
        if (null !== $event->getArgument('Order')) {
            return;
        }

        $Customer = $this->security->getUser();
        if (!$Customer instanceof Customer || !$Customer->isCompanyAdmin()) {
            return;
        }

        $Members = $Customer->getActiveCompanyMembers();
        if ($Members->isEmpty()) {
            return;
        }

        $orderNo = $event->getRequest()?->attributes->get('order_no');
        if (null === $orderNo) {
            return;
        }

        $Order = $this->orderRepository->findOneBy([
            'order_no' => $orderNo,
            'Customer' => $Members->toArray(),
        ]);

        if (null !== $Order) {
            $event->setArgument('Order', $Order);
        }
    }
}
