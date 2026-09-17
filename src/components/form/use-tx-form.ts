"use client";

import * as React from "react";
import { allowedSubs, findSub, isValidPair, type TxTypeKey, type SubCategory } from "@/lib/rules/tx-rules";
import { HOLDERS } from "@/lib/mock/entities";
import { BANKS } from "@/lib/mock/banks";
import { parseAmount } from "@/lib/format";
import { computeDisposal, type DisposalResult } from "@/lib/disposal/capital-gain";
import { splitRepayment, type RepaymentSplit } from "@/lib/disposal/repayment";
import { buildPosting } from "@/lib/ledger/posting";
import { PostingError, type IntercompanyNature, type PostingInput } from "@/lib/ledger/types";
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
  /** ชื่อไฟล์หลักฐานที่แนบ — นิติบุคคลต้องมีอย่างน้อยหนึ่งไฟล์ */
  attachments: string[];
  /** โอนระหว่างบัญชี — บัญชีปลายทาง */
  transferToBankId: string;
  /** ลักษณะของรายการข้ามผู้ถือ บังคับเมื่อบัญชีปลายทางเป็นของคนอื่น */
  intercompanyNature: IntercompanyNature | "";
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
  attachments: [],
  transferToBankId: "",
  intercompanyNature: "",
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

  /**
   * เปลี่ยนหมวดย่อยไปหมวดที่ตั้งค้างไม่ได้ → ล้างธงค้างรับ-ค้างจ่ายทิ้ง
   *
   * ถ้าปล่อยค้างไว้ ช่องติ๊กจะแสดงว่า "ไม่ติ๊กและกดไม่ได้" ขณะที่ค่าจริงยังเป็น true
   * ผู้ใช้จะเห็นปุ่มบันทึกถูกล็อกโดยไม่มีทางปลดจากหน้าจอ
   */
  const pickSub = React.useCallback((subCode: string) => {
    setDraft((d) => ({
      ...d,
      subCode,
      notYetPaid: findSub(subCode)?.sub.accrualCoa ? d.notYetPaid : false,
    }));
  }, []);

  /** เลือกประเภท → บังคับให้หมวดย่อยกลับมาอยู่ในชุดที่อนุญาตของประเภทนั้น */
  const pickType = React.useCallback((typeKey: TxTypeKey) => {
    const subs = allowedSubs(typeKey);
    setDraft((d) => {
      const subCode = isValidPair(typeKey, d.subCode) ? d.subCode : subs[0].code;
      return {
        ...d,
        typeKey,
        subCode,
        notYetPaid: findSub(subCode)?.sub.accrualCoa ? d.notYetPaid : false,
      };
    });
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
      const keepBank = bank?.ownerId === holderId;
      return {
        ...d,
        holderId,
        bankId: keepBank ? d.bankId : "",
        // ปลายทางเดิมอาจกลายเป็นบัญชีเดียวกับต้นทาง หรือเปลี่ยนจากข้ามผู้ถือเป็นในคนเดียวกัน
        // ค่าที่ค้างไว้จะกลายเป็นข้อมูลที่ไม่ตรงกับสิ่งที่เห็นบนจอ
        transferToBankId: "",
        intercompanyNature: "",
      };
    });
  }, []);

  /** เปลี่ยนบัญชีต้นทาง → ปลายทางที่ชนกันต้องหลุดไป ไม่งั้นจะได้รายการโอนเข้าบัญชีตัวเอง */
  const pickBank = React.useCallback((bankId: string) => {
    setDraft((d) => ({
      ...d,
      bankId,
      transferToBankId: d.transferToBankId === bankId ? "" : d.transferToBankId,
    }));
  }, []);

  /** เปลี่ยนปลายทาง → ลักษณะรายการข้ามผู้ถือที่ค้างไว้ต้องหลุดไปด้วย */
  const pickTransferTo = React.useCallback((transferToBankId: string) => {
    setDraft((d) => ({ ...d, transferToBankId, intercompanyNature: "" }));
  }, []);

  const sub: SubCategory | undefined = draft.subCode ? findSub(draft.subCode)?.sub : undefined;
  /** หมวดนี้ตั้งค้างรับ-ค้างจ่ายได้ไหม — ตารางกฎเป็นคนบอก ไม่ใช่ฟอร์ม */
  const canAccrue = !!sub?.accrualCoa;
  const subs = draft.typeKey ? allowedSubs(draft.typeKey) : [];

  const requires = React.useCallback((r: NonNullable<SubCategory["requires"]>[number]) => !!sub?.requires?.includes(r), [sub]);

  /**
   * ผู้ถือของบัญชีปลายทาง — **อ่านจากบัญชีเอง** ไม่ให้ผู้ใช้เลือก
   * (บทเรียนข้อ 2 ใน CLAUDE.md: อย่าเชื่อฟิลด์ที่ผู้ใช้เว้นได้)
   */
  const transferToOwnerId = React.useMemo(
    () => BANKS.find((b) => b.id === draft.transferToBankId)?.ownerId ?? null,
    [draft.transferToBankId]
  );
  const isCrossOwner = !!transferToOwnerId && transferToOwnerId !== draft.holderId;

  /** ช่องที่ยังขาดตามกฎของหมวดย่อยที่เลือก */
  const missing = React.useMemo(() => {
    const out: string[] = [];
    if (!draft.typeKey) out.push("ประเภทรายการ");
    if (!draft.subCode) out.push("หมวดย่อย");
    if (!draft.amount.trim()) out.push("จำนวนเงิน");
    if (requires("contact") && !draft.contactId) out.push("ผู้ติดต่อ");
    if (requires("asset") && !draft.assetId) out.push("ทรัพย์ที่ผูก");
    if (requires("transferTarget")) {
      if (!draft.transferToBankId) out.push("บัญชีปลายทาง");
      // ข้ามผู้ถือแล้วไม่ระบุลักษณะ = ไม่รู้ว่าเป็นหนี้ เป็นทุน หรือเป็นปันผล ลงบัญชีไม่ได้
      if (isCrossOwner && !draft.intercompanyNature) out.push("ลักษณะรายการข้ามผู้ถือ");
    }
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
  }, [draft, requires, isCrossOwner]);

  const reset = React.useCallback(() => {
    setDraft(EMPTY);
    setStep(1);
  }, []);

  /** Backlog ข้อ 4 — ตัวเลขกำไร/ขาดทุน คิดที่นี่ที่เดียว ทั้งแผงและพรีวิวอ่านตัวเดียวกัน */
  const disposal: DisposalResult | null = React.useMemo(() => {
    const costBasis = parseAmount(draft.disposal.costBasis);
    const salePrice = parseAmount(draft.disposal.salePrice);
    if (!(costBasis > 0 && salePrice > 0)) return null;
    try {
      return computeDisposal({
        costBasis,
        salePrice,
        sellingCosts: parseAmount(draft.disposal.sellingCosts),
        unrealizedGain: parseAmount(draft.disposal.unrealizedGain),
      });
    } catch {
      return null;
    }
  }, [draft.disposal]);

  /** Backlog ข้อ 5 — การแยกเงินต้น/ดอกเบี้ย พร้อมข้อความบอกเหตุถ้าแยกไม่ได้ */
  const repayment: { split: RepaymentSplit | null; error: string | null } = React.useMemo(() => {
    const installment = draft.loanTerms.schedule[0];
    const paid = parseAmount(draft.amount);
    const manual = isManualSplit(draft.repayment, !!installment);
    const touched =
      draft.repayment.manualPrincipal.trim() !== "" || draft.repayment.manualInterest.trim() !== "";

    // ยังไม่กรอกอะไรเลยก็อย่าเพิ่งขึ้น error ให้ตกใจ
    if (!(paid > 0) || (manual && !touched)) return { split: null, error: null };
    try {
      return {
        split: splitRepayment({
          amountPaid: paid,
          installment,
          manualPrincipal: manual ? parseAmount(draft.repayment.manualPrincipal) : undefined,
          manualInterest: manual ? parseAmount(draft.repayment.manualInterest) : undefined,
        }),
        error: null,
      };
    } catch (e) {
      return { split: null, error: e instanceof Error ? e.message : String(e) };
    }
  }, [draft.amount, draft.repayment, draft.loanTerms.schedule]);

  /**
   * แปลงฟอร์มเป็น input ของ ledger engine — **ที่เดียว** ที่ทำหน้าที่นี้
   *
   * ทั้งพรีวิวบรรทัดบัญชีในแผง พรีวิวตอนยืนยัน และการบันทึกจริง ต้องอ่านจากตัวนี้
   * ถ้ามีใครประกอบ input เองอีกที่ สิ่งที่ผู้ใช้เห็นกับสิ่งที่บันทึกจะแยกจากกันได้
   */
  const postingInput: PostingInput | null = React.useMemo(() => {
    if (!draft.typeKey || !draft.subCode) return null;
    const needsDisposal = !!sub?.requires?.includes("capitalGain");
    const needsSplit = !!sub?.requires?.includes("principalInterestSplit");

    return {
      typeKey: draft.typeKey,
      subCode: draft.subCode,
      // ขายทรัพย์: ยอดของรายการคือเงินสุทธิเสมอ ไม่ใช่สิ่งที่พิมพ์ในช่อง
      amount: needsDisposal && disposal ? disposal.netProceeds : parseAmount(draft.amount),
      ownerId: draft.holderId,
      bankAccountId: draft.bankId,
      assetId: draft.assetId || undefined,
      contactId: draft.contactId || undefined,
      memo: draft.note || undefined,
      attachments: draft.attachments.length ? draft.attachments : undefined,
      notYetPaid: draft.notYetPaid && canAccrue,
      disposal:
        needsDisposal && disposal
          ? {
              costBasis: disposal.costBasis,
              salePrice: disposal.salePrice,
              sellingCosts: disposal.sellingCosts,
            }
          : undefined,
      repayment:
        needsSplit && repayment.split
          ? { principal: repayment.split.principal, interest: repayment.split.interest }
          : undefined,
      transferToBankAccountId: draft.transferToBankId || undefined,
      intercompanyNature: draft.intercompanyNature || undefined,
    };
  }, [draft, sub, canAccrue, disposal, repayment.split]);

  /**
   * เหตุที่ engine จะปฏิเสธถ้ากดบันทึกตอนนี้
   *
   * เรียก `buildPosting()` **ตัวจริงที่ใช้ลงบัญชี** ไม่ใช่ตัวพรีวิว —
   * เพราะกติกาบางข้อ (นิติบุคคลต้องแนบหลักฐานและระบุคู่ค้า ทั้งฝั่งต้นทางและปลายทาง)
   * ไม่ได้ถูกตรวจในพรีวิว ถ้ากั้นปุ่มด้วยรายการช่องที่ขาดอย่างเดียว
   * ผู้ใช้จะกดบันทึกรายการที่ระบบปฏิเสธได้ — เท่ากับ override กติกาที่ห้าม override
   */
  const postingError = React.useMemo(() => {
    if (!postingInput) return null;
    try {
      buildPosting(postingInput);
      return null;
    } catch (e) {
      // ห้ามโยนต่อระหว่าง render — จอจะขาวทั้งหน้า ทั้งที่แค่กรอกยังไม่ครบ
      if (e instanceof PostingError) return e.message;
      return e instanceof Error ? e.message : String(e);
    }
  }, [postingInput]);

  /** กดบันทึกได้ก็ต่อเมื่อกรอกครบ **และ** engine ยอมรับ */
  const canSubmit = missing.length === 0 && !postingError;

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
    pickSub,
    pickHolder,
    pickBank,
    pickTransferTo,
    sub,
    subs,
    requires,
    canAccrue,
    missing,
    reset,
    disposal,
    repayment,
    transferToOwnerId,
    isCrossOwner,
    postingInput,
    postingError,
    canSubmit,
    setDerivedAmount,
  };
}

export type TxFormApi = ReturnType<typeof useTxForm>;
