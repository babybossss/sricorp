"use client";

import * as React from "react";
import { allowedSubs, findSub, isValidPair, type TxTypeKey, type SubCategory } from "@/lib/rules/tx-rules";
import { HOLDERS } from "@/lib/mock/entities";
import { BANKS } from "@/lib/mock/banks";
import { parseAmount } from "@/lib/format";
import type { PostingContext } from "@/lib/ledger/types";
import { EMPTY_LOAN_TERMS, type LoanTermsValue } from "./loan-terms-dialog";
import { EMPTY_DISPOSAL, EMPTY_REPAYMENT, isManualSplit, type DisposalValue, type RepaymentValue } from "./disposal-panel";

export type TxDraft = {
  typeKey: TxTypeKey | null;
  subCode: string;
  holderId: string;
  bankId: string;
  holderReason: string;
  amount: string;
  docDate: string;
  cashDate: string;
  notYetPaid: boolean;
  assetId: string;
  contactId: string;
  note: string;
  skipApproval: boolean;
  /** Backlog ข้อ 2 — เงื่อนไขสัญญา + ตารางงวด (เมื่อหมวดย่อยบังคับ loanTerms) */
  loanTerms: LoanTermsValue;
  /** Backlog ข้อ 4 — กำไร/ขาดทุนจากการขาย (เมื่อบังคับ capitalGain) */
  disposal: DisposalValue;
  /** Backlog ข้อ 5 — แยกเงินต้น/ดอกเบี้ย (เมื่อบังคับ principalInterestSplit) */
  repayment: RepaymentValue;
};

const EMPTY: TxDraft = {
  typeKey: null,
  subCode: "",
  holderId: HOLDERS[0].id,
  bankId: "",
  holderReason: "asset_personal",
  amount: "",
  docDate: "01/09/2026",
  cashDate: "03/09/2026",
  notYetPaid: false,
  assetId: "",
  contactId: "",
  note: "",
  skipApproval: false,
  loanTerms: EMPTY_LOAN_TERMS,
  disposal: EMPTY_DISPOSAL,
  repayment: EMPTY_REPAYMENT,
};

/**
 * สถานะฟอร์มบันทึกรายการ ใช้ร่วมกันทั้ง desktop modal และ mobile stepper
 *
 * ประเด็นสำคัญของ Backlog ข้อ 1: `subCode` ต้องอยู่ในชุดที่ `typeKey` อนุญาตเสมอ
 * เปลี่ยนประเภทเมื่อไร หมวดย่อยจะรีเซ็ตไปที่ตัวแรกที่ถูกต้อง ไม่ค้างค่าเดิมข้ามประเภท
 *
 * ประเด็นสำคัญของ Backlog ข้อ 3: state ตัวนี้อยู่เหนือ dialog สร้างผู้ติดต่อ
 * ปิด dialog แล้วค่าที่กรอกไว้ทุกช่องยังอยู่ครบ แค่ `contactId` ถูกเซ็ตให้
 */
export function useTxForm() {
  const [step, setStep] = React.useState(1);
  const [draft, setDraft] = React.useState<TxDraft>(EMPTY);

  const patch = React.useCallback((p: Partial<TxDraft>) => setDraft((d) => ({ ...d, ...p })), []);

  /** เลือกประเภท → บังคับให้หมวดย่อยกลับมาอยู่ในชุดที่อนุญาตของประเภทนั้น */
  const pickType = React.useCallback((typeKey: TxTypeKey) => {
    const subs = allowedSubs(typeKey);
    setDraft((d) => ({
      ...d,
      typeKey,
      subCode: isValidPair(typeKey, d.subCode) ? d.subCode : subs[0].code,
    }));
  }, []);

  /**
   * เลือกผู้ถือ → บังคับให้บัญชีธนาคารเป็นของผู้ถือรายนั้น
   *
   * ปล่อยให้เลือกข้ามกันไม่ได้: engine ปฏิเสธรายการที่บัญชีกับผู้ถือไม่ตรงกันอยู่แล้ว
   * (เงินของคนหนึ่งจะไปโผล่ในงบของอีกคน) ฟอร์มจึงต้องไม่เปิดให้เข้าสู่สถานะนั้นเลย
   */
  const pickHolder = React.useCallback((holderId: string) => {
    setDraft((d) => {
      const bank = BANKS.find((b) => b.id === d.bankId);
      return { ...d, holderId, bankId: bank?.ownerId === holderId ? d.bankId : "" };
    });
  }, []);

  const sub: SubCategory | undefined = draft.subCode ? findSub(draft.subCode)?.sub : undefined;
  const subs = draft.typeKey ? allowedSubs(draft.typeKey) : [];

  const requires = React.useCallback((r: NonNullable<SubCategory["requires"]>[number]) => !!sub?.requires?.includes(r), [sub]);

  /** ช่องที่ยังขาดตามกฎของหมวดย่อยที่เลือก */
  const missing = React.useMemo(() => {
    const out: string[] = [];
    if (!draft.typeKey) out.push("ประเภทรายการ");
    if (!draft.subCode) out.push("หมวดย่อย");
    if (!draft.amount.trim()) out.push("จำนวนเงิน");
    if (requires("contact") && !draft.contactId) out.push("ผู้ติดต่อ");
    if (requires("asset") && !draft.assetId) out.push("ทรัพย์ที่ผูก");
    // Backlog ข้อ 2: หมวดที่เป็นสัญญากู้ ต้องมีตารางงวดแล้วถึงจะส่งได้
    if (requires("loanTerms") && draft.loanTerms.schedule.length === 0) out.push("เงื่อนไขสัญญา + ตารางงวด");
    // Backlog ข้อ 4: ขายทรัพย์ต้องรู้ต้นทุนและราคาขายก่อน ไม่งั้นคำนวณกำไรไม่ได้
    if (requires("capitalGain") && (!draft.disposal.costBasis.trim() || !draft.disposal.salePrice.trim())) {
      out.push("ต้นทุนและราคาขาย");
    }
    // Backlog ข้อ 5: ถ้าไม่มีตารางงวดอ้างอิง ต้องระบุเงินต้น/ดอกเบี้ยเอง ระบบไม่เดาให้
    if (
      requires("principalInterestSplit") &&
      isManualSplit(draft.repayment, draft.loanTerms.schedule.length > 0) &&
      !draft.repayment.manualPrincipal.trim() &&
      !draft.repayment.manualInterest.trim()
    ) {
      out.push("เงินต้นและดอกเบี้ย");
    }
    return out;
  }, [draft, requires]);

  const reset = React.useCallback(() => {
    setDraft(EMPTY);
    setStep(1);
  }, []);

  /**
   * แปลงฟอร์มเป็น input ของ ledger engine — **ที่เดียว** ที่ทำหน้าที่นี้
   *
   * ทั้งพรีวิวบรรทัดบัญชีและการบันทึกจริงต้องอ่านจากตัวนี้
   * ส่วน `disposal` / `repayment` แผงเฉพาะทางเติมเองเพราะมันถือค่าที่กรอกไว้
   */
  const postingContext: PostingContext | null = React.useMemo(() => {
    if (!draft.typeKey || !draft.subCode) return null;
    return {
      typeKey: draft.typeKey,
      subCode: draft.subCode,
      amount: parseAmount(draft.amount),
      ownerId: draft.holderId,
      bankAccountId: draft.bankId,
      assetId: draft.assetId || undefined,
      contactId: draft.contactId || undefined,
      memo: draft.note || undefined,
    };
  }, [draft]);

  /** ยอดสุทธิที่แผงขายทรัพย์คำนวณได้ ต้องเป็นจำนวนเงินของรายการเสมอ */
  const setDerivedAmount = React.useCallback((n: number) => {
    setDraft((d) => (parseAmount(d.amount) === n ? d : { ...d, amount: n.toFixed(2) }));
  }, []);

  return {
    step,
    setStep,
    draft,
    patch,
    pickType,
    pickHolder,
    sub,
    subs,
    requires,
    missing,
    reset,
    postingContext,
    setDerivedAmount,
  };
}

export type TxFormApi = ReturnType<typeof useTxForm>;
