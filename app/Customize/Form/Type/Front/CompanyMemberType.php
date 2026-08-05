<?php

namespace Customize\Form\Type\Front;

use Eccube\Entity\Customer;
use Eccube\Form\Type\KanaType;
use Eccube\Form\Type\NameType;
use Eccube\Form\Type\PhoneNumberType;
use Eccube\Form\Type\RepeatedEmailType;
use Eccube\Form\Type\RepeatedPasswordType;
use Symfony\Component\Form\AbstractType;
use Symfony\Component\Form\FormBuilderInterface;
use Symfony\Component\OptionsResolver\OptionsResolver;

/**
 * 担当者アカウントの登録フォーム.
 *
 * 住所や会社名は管理者のものを引き継ぐため、入力項目には持たない。
 */
class CompanyMemberType extends AbstractType
{
    /**
     * @param array<string, mixed> $options
     */
    public function buildForm(FormBuilderInterface $builder, array $options): void
    {
        $builder
            ->add('name', NameType::class, [
                'required' => true,
            ])
            ->add('kana', KanaType::class, [])
            ->add('phone_number', PhoneNumberType::class, [
                'required' => true,
            ])
            ->add('email', RepeatedEmailType::class)
            ->add('plain_password', RepeatedPasswordType::class);
    }

    public function configureOptions(OptionsResolver $resolver): void
    {
        $resolver->setDefaults([
            'data_class' => Customer::class,
        ]);
    }

    public function getBlockPrefix(): string
    {
        return 'company_member';
    }
}
