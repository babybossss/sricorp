"use client";

import * as React from "react";
import { allowedSubs, findSub, isValidPair, type TxTypeKey, type SubCategory } from "@/lib/rules/tx-rules";
import { HOLDERS } from "@/lib/mock/entities";

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
    return out;
  }, [draft, requires]);

  const reset = React.useCallback(() => {
    setDraft(EMPTY);
    setStep(1);
  }, []);

  return { step, setStep, draft, patch, pickType, sub, subs, requires, missing, reset };
}

export type TxFormApi = ReturnType<typeof useTxForm>;
