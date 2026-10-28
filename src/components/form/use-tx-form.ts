"use client";

import * as React from "react";
import {
  allowedSubs,
  findSub,
  isValidPair,
  canAccrueFromForm,
  accrualCheck,
  whtCheck,
  type TxTypeKey,
  type SubCategory,
} from "@/lib/rules/tx-rules";
import { dmyToIso, parseAmount, todayDmy } from "@/lib/format";
import { computeDisposal, type DisposalResult } from "@/lib/disposal/capital-gain";
import { splitRepayment, type RepaymentSplit } from "@/lib/disposal/repayment";
import { buildPosting, buildPostingDraft } from "@/lib/ledger/posting";
// resolver ของผู้ถือ/บัญชี สร้างจากข้อมูลจริงใน DB แล้วส่งเข้า engine จากชั้นนี้ — engine ไม่ import ข้อมูลเอง
import { PostingError, type PostingInput } from "@/lib/ledger/types";
import { useReference, useReferenceState, useResolver } from "@/components/reference/reference-provider";
import { usePermissions } from "@/components/auth/permissions-provider";
import { postEntry, type PostEntryOutcome } from "@/app/actions/post-entry";
import { listOpenSources, type OpenSource } from "@/app/actions/open-sources";
import { accrualReductionsOf } from "@/lib/db/clearing-link";
import { notWiredReason } from "@/lib/db/post-entry";
import { loadFxContext } from "@/app/actions/fx-context";
import { loadDisposalContext } from "@/app/actions/disposal-context";
import { disposalFor, type DisposalContext } from "@/lib/db/disposal-context";
import { loadBalanceMove } from "@/app/actions/balance-move";
import { loadTagCatalog } from "@/app/actions/tags";
import { checkTagSelection, pruneWeights, withSoleTagWeight, type SelectionCheck } from "@/lib/tags/selection";
import type { Tag, TagKind, TagWeights } from "@/components/tags/types";
import type { HiddenKind } from "@/lib/tags/acceptance";
import { movesWholeBalance, type BalanceMove } from "@/lib/db/balance-move";
import type { FxAccountContext } from "@/lib/db/fx-context";
import { fxInputFor, fxKindOf } from "@/lib/db/fx-input";
import { EMPTY_FX, fxChoiceOf, type FxDraft } from "./fx-value";
import { showsBankField } from "./bank-field";
import { EMPTY_CASH_FIELDS, cashFieldsFor, type CashFields } from "./cash-fields";
import { EMPTY_LOAN_TERMS, type LoanTermsValue } from "./loan-terms-dialog";
import { EMPTY_WHT, type WhtDraft } from "./wht-value";
import {
  EMPTY_DISPOSAL,
  EMPTY_REPAYMENT,
  isManualSplit,
  type DisposalValue,
  type RepaymentValue,
} from "./disposal-panel";

/**
 * ช่องฝั่งเงินสด (`bankId` · `cashDate` · `transferToBankId` · `intercompanyNature`)
 * มาจาก `CashFields` ใน `cash-fields.ts` — ที่เดียวกับกฎที่ล้างมันตอนเปลี่ยนหมวด
 * ประกาศซ้ำที่นี่แล้วลืมเพิ่มในกฎล้าง = ค่าที่มองไม่เห็นหลุดลง DB
 */
export type TxDraft = CashFields & {
  typeKey: TxTypeKey | null;
  subCode: string;
  holderId: string;
  amount: string;
  docDate: string;
  notYetPaid: boolean;
  assetId: string;
  contactId: string;
  note: string;
  /** path ของไฟล์หลักฐานที่อัปโหลดขึ้น Storage แล้ว — นิติบุคคลต้องมีอย่างน้อยหนึ่งไฟล์ */
  attachments: string[];
  /** Backlog ข้อ 2 — เงื่อนไขสัญญา + ตารางงวด (เมื่อหมวดย่อยบังคับ loanTerms) */
  loanTerms: LoanTermsValue;
  /** Backlog ข้อ 4 — กำไร/ขาดทุนจากการขาย (เมื่อบังคับ capitalGain) */
  disposal: DisposalValue;
  /** Backlog ข้อ 5 — แยกเงินต้น/ดอกเบี้ย (เมื่อบังคับ principalInterestSplit) */
  repayment: RepaymentValue;
  /** ผู้จ่ายหักภาษี ณ ที่จ่ายไว้ (เฉพาะหมวดที่ตารางกฎยอมให้หักได้และเงินเคลื่อนจริง) */
  wht: WhtDraft;
  /** ใบค้างที่รายการนี้ชำระ — เลือกเมื่อรายการลดลูกหนี้/เจ้าหนี้และผู้ถือมีของค้างเปิดอยู่หลายใบ */
  clearsSourceId: string;
  /** หมวดแปลงค่า/แลกเงินตรา — เลือกอัตราจากตาราง + จำนวนเงินตราที่แลก (ยอดคงเหลือ/อัตราตามบัญชี/ผลต่างที่ค้างอ่านจากสมุด) */
  fx: FxDraft;
  /** tag ที่ติดกับรายการนี้ (ADR 0002) — เลือกจากแค็ตตาล็อกเท่านั้น */
  tagIds: string[];
  /** สัดส่วนของ tag ในชนิดที่ถ่วงน้ำหนัก (ADR 0003) · 0.6 = 60% · null = ยังไม่ได้กรอก */
  tagWeights: TagWeights;
};

/**
 * ค่าตั้งต้นของฟอร์ม
 *
 * ผู้ถือ **ไม่มีค่าตั้งต้น** — ต้องเลือกเอง (ของเดิมเลือกคนแรกให้ ซึ่งเมื่อเป็นเงินจริง
 * คนที่กดผ่านโดยไม่อ่านจะลงรายการในชื่อคนผิดเงียบๆ)
 * วันที่ตั้งต้นเป็นวันนี้ตามเวลากรุงเทพฯ (ของเดิมเป็นวันที่จำลอง 01/09/2026)
 */
const freshDraft = (): TxDraft => ({
  ...EMPTY_CASH_FIELDS,
  cashDate: todayDmy(),
  typeKey: null,
  subCode: "",
  holderId: "",
  amount: "",
  docDate: todayDmy(),
  // ตั้งต้นเป็น "ยังไม่ได้รับ-จ่าย" ตามที่ลูกพี่สั่ง 06/10 — ต้องติ๊กยืนยันถึงจะเป็นเงินสด
  // สอดคล้องกับ D-068: เงินเข้าบัญชีต่อเมื่อมีคนยืนยันว่าเงินเคลื่อนจริง
  notYetPaid: true,
  assetId: "",
  contactId: "",
  note: "",
  attachments: [],
  loanTerms: EMPTY_LOAN_TERMS,
  disposal: EMPTY_DISPOSAL,
  repayment: EMPTY_REPAYMENT,
  wht: EMPTY_WHT,
  clearsSourceId: "",
  fx: EMPTY_FX,
  tagIds: [],
  tagWeights: {},
});

/** ค่า "ยังไม่ได้รับ-จ่าย" ตั้งต้น — อ้างจากฟอร์มเปล่าที่เดียว ไม่เขียนซ้ำ */
const DEFAULT_NOT_YET_PAID = freshDraft().notYetPaid;

/**
 * สถานะฟอร์มบันทึกรายการ ใช้ร่วมกันทั้ง desktop modal และ mobile stepper
 *
 * ประเด็นสำคัญของ Backlog ข้อ 1: `subCode` ต้องอยู่ในชุดที่ `typeKey` อนุญาตเสมอ
 * เปลี่ยนประเภทเมื่อไร หมวดย่อยจะรีเซ็ตไปที่ตัวแรกที่ถูกต้อง ไม่ค้างค่าเดิมข้ามประเภท
 *
 * ประเด็นสำคัญของ Backlog ข้อ 3: state ตัวนี้อยู่เหนือ dialog สร้างผู้ติดต่อ
 * ปิด dialog แล้วค่าที่กรอกไว้ทุกช่องยังอยู่ครบ แค่ `contactId` ถูกเซ็ตให้
 */
/**
 * ธงค้างรับ-ค้างจ่ายตอนเปลี่ยนหมวดย่อย
 *
 * หมวดที่ตั้งค้างไม่ได้ → บังคับเป็นเงินสด ไม่งั้นช่องติ๊กจะแสดงว่า "กดไม่ได้"
 * ขณะที่ค่าจริงยังเป็น true แล้วปุ่มบันทึกจะถูกล็อกโดยไม่มีทางปลดจากหน้าจอ
 *
 * ย้อนกลับมาหมวดที่ตั้งค้างได้ → คืนค่าตั้งต้น ไม่ใช่ค่าที่ถูกบังคับทิ้งไว้
 * ไม่งั้นแค่แวะหมวดที่ตั้งค้างไม่ได้ครั้งเดียว รายการที่เหลือทั้งวันจะกลายเป็น
 * "รับเงินแล้ว" เงียบๆ ทั้งที่ผู้ใช้ไม่เคยติ๊กอะไรเลย
 */
function accrualFlagFor(nextSub: string, prevSub: string, current: boolean): boolean {
  const accruable = (code: string) => {
    const s = findSub(code)?.sub;
    return !!s && canAccrueFromForm(s);
  };
  if (!accruable(nextSub)) return false;
  return accruable(prevSub) ? current : DEFAULT_NOT_YET_PAID;
}

export function useTxForm() {
  const [step, setStep] = React.useState(1);
  const [draft, setDraft] = React.useState<TxDraft>(freshDraft);
  const [submitting, setSubmitting] = React.useState(false);
  const submittingRef = React.useRef(false);
  const refState = useReferenceState();
  const reference = useReference();
  const resolver = useResolver();
  const permissions = usePermissions();
  /** ลงสมุดโดยตรงต้องมีสิทธิ์อนุมัติเข้าสมุด (RLS `txn_insert`) — ส่งร่างให้ผู้อนุมัติยังไม่ได้ต่อกับ DB */
  const canPost = permissions.has("ledger.approve");

  const patch = React.useCallback((p: Partial<TxDraft>) => setDraft((d) => ({ ...d, ...p })), []);


  const pickSub = React.useCallback((subCode: string) => {
    setDraft((d) => ({
      ...d,
      // อัตราที่เลือกไว้เป็นของหมวดก่อนหน้า (ทิศแปลงค่า/แลกเงินต่างกัน) — ไม่ค้างข้ามหมวด
      fx: subCode === d.subCode ? d.fx : EMPTY_FX,
      subCode,
      ...cashFieldsFor(subCode, d),
      notYetPaid: accrualFlagFor(subCode, d.subCode, d.notYetPaid),
    }));
  }, []);

  /** เลือกประเภท → บังคับให้หมวดย่อยกลับมาอยู่ในชุดที่อนุญาตของประเภทนั้น */
  const pickType = React.useCallback((typeKey: TxTypeKey) => {
    const subs = allowedSubs(typeKey);
    setDraft((d) => {
      const subCode = isValidPair(typeKey, d.subCode) ? d.subCode : subs[0].code;
      return {
        ...d,
        fx: subCode === d.subCode ? d.fx : EMPTY_FX,
        typeKey,
        subCode,
        ...cashFieldsFor(subCode, d),
        notYetPaid: accrualFlagFor(subCode, d.subCode, d.notYetPaid),
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
      const bank = reference.banks.find((b) => b.id === d.bankId);
      const keepBank = bank?.ownerId === holderId;
      return {
        ...d,
        holderId,
        bankId: keepBank ? d.bankId : "",
        fx: keepBank ? d.fx : EMPTY_FX,
        // ไฟล์หลักฐานอยู่ใต้โฟลเดอร์ของผู้ถือที่อัปโหลดให้ — เปลี่ยนผู้ถือแล้วไฟล์เดิมใช้เป็นหลักฐานไม่ได้
        attachments: holderId === d.holderId ? d.attachments : [],
        // ปลายทางเดิมอาจกลายเป็นบัญชีเดียวกับต้นทาง หรือเปลี่ยนจากข้ามผู้ถือเป็นในคนเดียวกัน
        // ค่าที่ค้างไว้จะกลายเป็นข้อมูลที่ไม่ตรงกับสิ่งที่เห็นบนจอ
        transferToBankId: "",
        intercompanyNature: "",
      };
    });
  }, [reference.banks]);

  /** เปลี่ยนบัญชีต้นทาง → ปลายทางที่ชนกันต้องหลุดไป ไม่งั้นจะได้รายการโอนเข้าบัญชีตัวเอง */
  const pickBank = React.useCallback((bankId: string) => {
    setDraft((d) => ({
      ...d,
      bankId,
      // ยอดคงเหลือและอัตราตามบัญชีเป็นของบัญชีเดิม — เปลี่ยนบัญชีแล้วอัตราที่เลือกไว้ต้องเลือกใหม่
      fx: bankId === d.bankId ? d.fx : EMPTY_FX,
      transferToBankId: d.transferToBankId === bankId ? "" : d.transferToBankId,
    }));
  }, []);

  /** เปลี่ยนปลายทาง → ลักษณะรายการข้ามผู้ถือที่ค้างไว้ต้องหลุดไปด้วย */
  const pickTransferTo = React.useCallback((transferToBankId: string) => {
    setDraft((d) => ({ ...d, transferToBankId, intercompanyNature: "" }));
  }, []);

  const sub: SubCategory | undefined = draft.subCode ? findSub(draft.subCode)?.sub : undefined;
  /**
   * หมวดนี้ตั้งค้างรับ-ค้างจ่ายได้ไหม — ตารางกฎเป็นคนบอก ไม่ใช่ฟอร์ม
   *
   * ถามฟังก์ชันเดียวกับที่ `buildPosting()` ใช้ ไม่ใช่เช็ค `accrualCoa` เอง
   * ไม่งั้นช่องติ๊กจะเปิดให้ติ๊กในหมวดที่ engine ปฏิเสธ (บทเรียนข้อ 5 และ 6)
   */
  const accrual = sub ? accrualCheck(sub) : undefined;
  const canAccrue = !!accrual?.ok;
  /**
   * เหตุผลที่ตั้งค้างไม่ได้ — เอามาจากตารางกฎตัวเดียวกับที่ engine ใช้ปฏิเสธ
   * ผู้ใช้ที่ซื้อทรัพย์แบบยังไม่จ่ายต้องอ่านได้ว่าทำไมติ๊กไม่ได้ ไม่ใช่เจอช่องเทาๆ
   */
  const accrualWhy = accrual && !accrual.ok ? accrual.why : undefined;
  const subs = draft.typeKey ? allowedSubs(draft.typeKey) : [];
  /**
   * เงินเคลื่อนจริงในรายการนี้ไหม — มีช่องบัญชี (ตารางกฎ) และไม่ใช่รายการค้างรับ-ค้างจ่าย
   * ใช้ตัดสินว่า "วันที่เงินเข้า/ออกจริง" ต้องกรอกหรือไม่ · ตัวตัดสินสุดท้ายคือบรรทัดที่ engine คืน (ดู toPostEntryPayload)
   */
  const moneyMoved = showsBankField(sub) && !(draft.notYetPaid && canAccrue);
  /** หมวดที่เส้นทางบันทึกยังต่อไม่ครบ (สัญญากู้ · ขายทรัพย์) — บอกเหตุผล ไม่ใช่บันทึกครึ่งเดียว */
  const notWired = notWiredReason(sub);

  /**
   * หมวดแปลงค่า/แลกเงินตรา — ยอดเงินตราคงเหลือ อัตราที่ยอดบาทตั้งอยู่ และผลต่างที่ค้างใน 3410 **อ่านจากสมุด** ผ่าน server action
   * (ไม่ให้พิมพ์ · D-115) ผู้ใช้เลือกแค่วันของอัตราจากตารางอัตราและจำนวนที่แลก · ตอนบันทึกจริง server อ่านซ้ำเอง ไม่เชื่อค่าที่ฟอร์มถือ
   */
  const fxKind = fxKindOf(sub);
  // ซื้อเงินตรา: บัญชีที่ต้องอ่านสมุด/สกุล/อัตราคือบัญชี **ปลายทาง** (FCD) · แปลงค่า/แลก: บัญชีเงินตราที่เลือกเป็นบัญชีหลัก
  const fxAccountId = fxKind === "acquisition" ? draft.transferToBankId : draft.bankId;
  const fxKey = fxKind && draft.holderId && fxAccountId ? `${draft.holderId}|${fxAccountId}` : null;
  /** กดโหลดอัตรา/ยอดใหม่ — เผื่อเพิ่งเพิ่มอัตราที่หน้าตั้งค่าแล้วกลับมาที่ฟอร์มเดิม */
  const [fxReloadTick, setFxReloadTick] = React.useState(0);
  const reloadFx = React.useCallback(() => setFxReloadTick((n) => n + 1), []);
  const [fxState, setFxState] = React.useState<{ key: string | null; loading: boolean; error: string | null; ctx: FxAccountContext | null }>({
    key: null,
    loading: false,
    error: null,
    ctx: null,
  });
  React.useEffect(() => {
    if (!fxKey) {
      setFxState({ key: null, loading: false, error: null, ctx: null });
      return;
    }
    let live = true;
    const [ownerId, bankAccountId] = fxKey.split("|");
    setFxState({ key: fxKey, loading: true, error: null, ctx: null });
    loadFxContext({ ownerId, bankAccountId })
      .then((r) => {
        if (!live) return;
        setFxState(r.ok ? { key: fxKey, loading: false, error: null, ctx: r.ctx } : { key: fxKey, loading: false, error: r.message, ctx: null });
      })
      .catch(() => live && setFxState({ key: fxKey, loading: false, error: "ติดต่อเซิร์ฟเวอร์ไม่ได้ จึงโหลดข้อมูลเงินตราจากสมุดไม่ได้", ctx: null }));
    return () => {
      live = false;
    };
  }, [fxKey, fxReloadTick]);
  const fxCtx = fxState.key === fxKey ? fxState.ctx : null;
  const fxResult = React.useMemo(
    () => (fxKind && sub && fxCtx ? fxInputFor(sub, fxCtx, fxChoiceOf(draft.fx)) : null),
    [fxKind, sub, fxCtx, draft.fx]
  );
  // ยอดบาทที่ต้องกรอกมาจากอัตราที่เลือก — ช่องจำนวนเงินตามเสมอ (อ่านอย่างเดียว) ไม่ให้พิมพ์ทับจนขัดกับอัตรา
  const fxAmount = fxResult?.ok ? fxResult.amount : null;
  React.useEffect(() => {
    if (fxAmount !== null) setDraft((d) => (parseAmount(d.amount) === fxAmount ? d : { ...d, amount: fxAmount.toFixed(2) }));
  }, [fxAmount]);
  /**
   * หักภาษี ณ ที่จ่ายได้ไหม — ถามตารางกฎ (`whtCheck`) ไม่ไล่ชื่อหมวด · ต้องมีเงินเคลื่อนจริงด้วย
   * (ตั้งค้างแล้วยังไม่มีใครหัก — engine ปฏิเสธอยู่แล้ว ที่นี่แค่ไม่เปิดช่องให้กรอก)
   */
  const whtEligible = !!sub && whtCheck(sub).ok && moneyMoved;
  const whtOn = whtEligible && draft.wht.on;

  /**
   * ขายทรัพย์ — ต้นทุนทั้งก้อน ค่ารีโนเวทสะสม และส่วนเกินทุนที่ค้างอยู่ **อ่านจากสมุด** ผ่าน server action (ผู้ใช้ไม่ได้กรอก · D-115)
   * ผู้ใช้กรอกได้แค่ราคาขายกับค่าใช้จ่ายในการขาย · ตอนบันทึกจริง server อ่านซ้ำเองและทิ้งค่าที่ฟอร์มส่งมา
   */
  const sellsAsset = !!sub?.requires?.includes("capitalGain");
  const disposalKey = sellsAsset && draft.holderId && draft.assetId ? `${draft.holderId}|${draft.assetId}` : null;
  const [disposalState, setDisposalState] = React.useState<{ key: string | null; loading: boolean; error: string | null; ctx: DisposalContext | null }>({
    key: null,
    loading: false,
    error: null,
    ctx: null,
  });
  React.useEffect(() => {
    if (!disposalKey) {
      setDisposalState({ key: null, loading: false, error: null, ctx: null });
      return;
    }
    let live = true;
    const [ownerId, assetId] = disposalKey.split("|");
    setDisposalState({ key: disposalKey, loading: true, error: null, ctx: null });
    loadDisposalContext({ ownerId, assetId })
      .then((r) => {
        if (!live) return;
        setDisposalState(r.ok ? { key: disposalKey, loading: false, error: null, ctx: r.ctx } : { key: disposalKey, loading: false, error: r.message, ctx: null });
      })
      .catch(() => live && setDisposalState({ key: disposalKey, loading: false, error: "ติดต่อเซิร์ฟเวอร์ไม่ได้ จึงอ่านต้นทุนของทรัพย์จากสมุดไม่ได้", ctx: null }));
    return () => {
      live = false;
    };
  }, [disposalKey]);
  const disposalCtx = disposalState.key === disposalKey ? disposalState.ctx : null;
  const disposalBuild = React.useMemo(
    () =>
      sellsAsset && disposalCtx
        ? disposalFor(disposalCtx, { salePrice: parseAmount(draft.disposal.salePrice), sellingCosts: parseAmount(draft.disposal.sellingCosts) })
        : null,
    [sellsAsset, disposalCtx, draft.disposal.salePrice, draft.disposal.sellingCosts]
  );

  /**
   * ย้ายวัตถุประสงค์ทรัพย์ (ธง `wholeBalanceMove`) — ยอดคงเหลือของทรัพย์ในบัญชีต้นทาง **อ่านจากสมุด** ผ่าน server action
   * ผู้ใช้เลือกแค่ทรัพย์ ไม่มีช่องพิมพ์ยอด (D-115) · ตอนบันทึกจริง server อ่านซ้ำเองและทิ้งค่าที่ฟอร์มส่งมา
   */
  const movesBalance = movesWholeBalance(sub);
  const moveKey = movesBalance && draft.holderId && draft.assetId ? `${draft.holderId}|${draft.assetId}|${draft.subCode}` : null;
  const [moveState, setMoveState] = React.useState<{ key: string | null; loading: boolean; error: string | null; balanceMove: BalanceMove | null }>({
    key: null,
    loading: false,
    error: null,
    balanceMove: null,
  });
  React.useEffect(() => {
    if (!moveKey) {
      setMoveState({ key: null, loading: false, error: null, balanceMove: null });
      return;
    }
    let live = true;
    const [ownerId, assetId, subCode] = moveKey.split("|");
    setMoveState({ key: moveKey, loading: true, error: null, balanceMove: null });
    loadBalanceMove({ ownerId, assetId, subCode })
      .then((r) => {
        if (!live) return;
        setMoveState(r.ok ? { key: moveKey, loading: false, error: null, balanceMove: r.balanceMove } : { key: moveKey, loading: false, error: r.message, balanceMove: null });
      })
      .catch(() => live && setMoveState({ key: moveKey, loading: false, error: "ติดต่อเซิร์ฟเวอร์ไม่ได้ จึงอ่านยอดต้นทุนของทรัพย์จากสมุดไม่ได้", balanceMove: null }));
    return () => {
      live = false;
    };
  }, [moveKey]);
  const balanceMove = moveState.key === moveKey ? moveState.balanceMove : null;
  // ช่องจำนวนเงินตามยอดจากสมุดเสมอ (อ่านอย่างเดียว) · ไม่มียอด = ล้างช่อง ไม่ค้างยอดของทรัพย์ชิ้นก่อน
  const moveAmount = balanceMove?.sourceBalance ?? null;
  const prevMovesBalance = React.useRef(false);
  React.useEffect(() => {
    if (movesBalance) {
      setDraft((d) => {
        const next = moveAmount !== null ? moveAmount.toFixed(2) : "";
        return d.amount === next ? d : { ...d, amount: next };
      });
    } else if (prevMovesBalance.current) {
      setDraft((d) => (d.amount ? { ...d, amount: "" } : d));
    }
    prevMovesBalance.current = movesBalance;
  }, [movesBalance, moveAmount]);

  const requires = React.useCallback((r: NonNullable<SubCategory["requires"]>[number]) => !!sub?.requires?.includes(r), [sub]);

  /**
   * ผู้ถือของบัญชีปลายทาง — **อ่านจากบัญชีเอง** ไม่ให้ผู้ใช้เลือก
   * (บทเรียนข้อ 2 ใน CLAUDE.md: อย่าเชื่อฟิลด์ที่ผู้ใช้เว้นได้)
   */
  const transferToOwnerId = React.useMemo(
    () => reference.banks.find((b) => b.id === draft.transferToBankId)?.ownerId ?? null,
    [reference.banks, draft.transferToBankId]
  );
  const isCrossOwner = !!transferToOwnerId && transferToOwnerId !== draft.holderId;

  /** ช่องที่ยังขาดตามกฎของหมวดย่อยที่เลือก */
  const missingBase = React.useMemo(() => {
    const out: string[] = [];
    if (!draft.holderId) out.push("ผู้ถือกรรมสิทธิ์");
    if (!draft.typeKey) out.push("ประเภทรายการ");
    if (!draft.subCode) out.push("หมวดย่อย");
    if (!draft.amount.trim()) out.push("จำนวนเงิน");
    // วันที่ต้องเป็นวันที่จริง (ปี ค.ศ.) — ถ้าอ่านไม่ออก server จะปฏิเสธ ไม่เดาให้
    if (!dmyToIso(draft.docDate)) out.push("วันที่เอกสาร (วว/ดด/ปปปป)");
    if (moneyMoved && !dmyToIso(draft.cashDate)) out.push("วันที่เงินเข้า/ออกจริง (วว/ดด/ปปปป)");
    if (requires("contact") && !draft.contactId) out.push("ผู้ติดต่อ");
    // แปลงค่า/แลกเงินตรา: ต้องอ่านสมุดได้และเลือกอัตราครบ — ข้อความจาก fxInputFor บอกว่าขาดอะไร
    if (fxKind) {
      if (fxKind === "acquisition" && !draft.bankId) out.push("บัญชีบาทที่จ่าย");
      else if (!fxAccountId) out.push(fxKind === "acquisition" ? "บัญชีสกุลต่างประเทศที่เงินตราเข้า" : "บัญชีเงินฝากสกุลต่างประเทศ");
      else if (fxState.loading) out.push("ข้อมูลเงินตราจากสมุด (กำลังโหลด)");
      else if (!fxCtx) out.push(fxState.error ? `ข้อมูลเงินตราจากสมุด — ${fxState.error}` : "ข้อมูลเงินตราจากสมุด");
      else if (fxResult && !fxResult.ok) out.push(fxResult.message);
    }
    if (whtOn && (!draft.wht.rate.trim() || !draft.wht.amount.trim())) out.push("อัตราและยอดภาษีที่ถูกหัก (จากใบรับรอง)");
    if (requires("asset") && !draft.assetId) out.push("โปรเจค (ทรัพย์)");
    if (requires("transferTarget")) {
      if (!draft.transferToBankId) out.push("บัญชีปลายทาง");
      // ข้ามผู้ถือแล้วไม่ระบุลักษณะ = ไม่รู้ว่าเป็นหนี้ เป็นทุน หรือเป็นปันผล ลงบัญชีไม่ได้
      if (isCrossOwner && !draft.intercompanyNature) out.push("ลักษณะรายการข้ามผู้ถือ");
    }
    // Backlog ข้อ 2: หมวดที่เป็นสัญญากู้ ต้องมีตารางงวดแล้วถึงจะส่งได้
    if (requires("loanTerms") && draft.loanTerms.schedule.length === 0) out.push("เงื่อนไขสัญญา + ตารางงวด");
    // ขายทรัพย์: ต้องเลือกทรัพย์ (ระบบอ่านต้นทุนจากสมุด) และกรอกราคาขาย · ถ้าอ่านต้นทุนไม่ได้/ขายผ่านฟอร์มไม่ได้ ข้อความบอกเหตุที่ตรงนี้
    if (requires("capitalGain")) {
      if (!draft.assetId) out.push("ทรัพย์ที่ขาย (ระบบอ่านต้นทุนจากสมุดให้)");
      else if (disposalState.loading) out.push("ต้นทุนของทรัพย์จากสมุด (กำลังโหลด)");
      else if (!disposalCtx) out.push(disposalState.error ? `ต้นทุนของทรัพย์จากสมุด — ${disposalState.error}` : "ต้นทุนของทรัพย์จากสมุด");
      else if (!draft.disposal.salePrice.trim()) out.push("ราคาขาย");
      else if (disposalBuild && !disposalBuild.ok) out.push(disposalBuild.message);
    }
    // ย้ายวัตถุประสงค์ทรัพย์: ต้องเลือกทรัพย์ (ช่อง "โปรเจค" ข้างบนแจ้งอยู่แล้ว) และอ่านยอดจากสมุดได้ — ข้อความบอกเหตุที่ตรงนี้
    if (movesBalance && draft.assetId) {
      if (moveState.key !== moveKey || moveState.loading) out.push("ยอดต้นทุนของทรัพย์จากสมุด (กำลังโหลด)");
      else if (!balanceMove) out.push(moveState.error ?? "ยอดต้นทุนของทรัพย์จากสมุด");
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
  }, [draft, requires, isCrossOwner, moneyMoved, whtOn, fxKind, fxAccountId, fxState, fxCtx, fxResult, disposalState, disposalCtx, disposalBuild, movesBalance, moveState, moveKey, balanceMove]);

  const reset = React.useCallback(() => {
    setDraft(freshDraft());
    setStep(1);
  }, []);

  /** Backlog ข้อ 4 — ตัวเลขกำไร/ขาดทุน คิดที่นี่ที่เดียว ทั้งแผงและพรีวิวอ่านตัวเดียวกัน */
  const disposal: DisposalResult | null = React.useMemo(() => {
    if (!disposalBuild?.ok) return null;
    const d = disposalBuild.disposal;
    try {
      return computeDisposal({
        costBasis: d.costBasis,
        salePrice: d.salePrice,
        sellingCosts: d.sellingCosts,
        unrealizedAdjustment: d.priorSurplus ?? 0,
      });
    } catch {
      return null;
    }
  }, [disposalBuild]);

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
      amount: needsDisposal && disposal
        ? disposal.netProceeds
        : fxResult?.ok
          ? fxResult.amount
          : balanceMove
            ? balanceMove.sourceBalance // ย้ายทั้งก้อน: ยอดคือยอดจากสมุด ไม่ใช่สิ่งที่พิมพ์
            : parseAmount(draft.amount),
      ownerId: draft.holderId,
      bankAccountId: draft.bankId,
      assetId: draft.assetId || undefined,
      contactId: draft.contactId || undefined,
      memo: draft.note || undefined,
      attachments: draft.attachments.length ? draft.attachments : undefined,
      notYetPaid: draft.notYetPaid && canAccrue,
      // ทั้งก้อนมาจากสมุด (disposalFor) — ใช้พรีวิวและกั้นปุ่ม · server ประกอบเองใหม่ตอนบันทึก
      disposal: needsDisposal && disposalBuild?.ok ? disposalBuild.disposal : undefined,
      repayment:
        needsSplit && repayment.split
          ? { principal: repayment.split.principal, interest: repayment.split.interest }
          : undefined,
      transferToBankAccountId: draft.transferToBankId || undefined,
      intercompanyNature: draft.intercompanyNature || undefined,
      // ข้อมูลเงินตราที่อ่านจากสมุด + อัตราที่เลือก (ใช้พรีวิวและกั้นปุ่ม · server ประกอบเองใหม่ตอนบันทึก)
      ...(fxResult?.ok ? fxResult.patch : {}),
      // ยอดคงเหลือที่อ่านจากสมุด (ใช้พรีวิวและกั้นปุ่ม · server อ่านซ้ำเองตอนบันทึก)
      balanceMove: movesBalance && balanceMove ? balanceMove : undefined,
      // ส่งเมื่อติ๊กว่าถูกหักและหมวดนี้หักได้เท่านั้น — ค่าที่ค้างจากหมวดอื่นไม่หลุดไปกับรายการ
      wht: whtOn
        ? {
            rate: parseAmount(draft.wht.rate),
            amount: parseAmount(draft.wht.amount),
            certificateNo: draft.wht.certificateNo.trim() || undefined,
          }
        : undefined,
    };
  }, [draft, sub, canAccrue, disposal, disposalBuild, repayment.split, whtOn, fxResult, movesBalance, balanceMove]);

  /**
   * รายการนี้ลดลูกหนี้/เจ้าหนี้ไหม — ถาม engine (ร่าง) แล้วอ่านบรรทัดที่ได้ ไม่ใช่เดาจากรหัสหมวด
   * ถ้าลด → ไปอ่านของค้างที่ยังเปิดอยู่จาก DB (ยอดคงเหลือไม่คำนวณในหน้าจอ) ให้ผู้ใช้เลือกใบเมื่อมีหลายใบ
   */
  const reduction = React.useMemo(() => {
    if (!postingInput) return null;
    try {
      const r = accrualReductionsOf(buildPostingDraft(postingInput, resolver).transactions);
      return r.length === 1 ? r[0] : null;
    } catch {
      return null;
    }
  }, [postingInput, resolver]);
  const reductionKey = reduction ? `${reduction.ownerId}|${reduction.account}` : null;
  const [sources, setSources] = React.useState<{ key: string | null; items: OpenSource[]; loading: boolean; error: string | null }>({
    key: null,
    items: [],
    loading: false,
    error: null,
  });
  React.useEffect(() => {
    if (!reductionKey) {
      setSources({ key: null, items: [], loading: false, error: null });
      setDraft((d) => (d.clearsSourceId ? { ...d, clearsSourceId: "" } : d));
      return;
    }
    let live = true;
    const [ownerId, account] = reductionKey.split("|");
    setSources({ key: reductionKey, items: [], loading: true, error: null });
    listOpenSources({ ownerId, account })
      .then((r) => {
        if (!live) return;
        if (!r.ok) {
          setSources({ key: reductionKey, items: [], loading: false, error: r.message });
          return;
        }
        setSources({ key: reductionKey, items: r.items, loading: false, error: null });
        // ใบที่เลือกไว้ไม่อยู่ในรายการแล้ว (เปลี่ยนผู้ถือ/หมวด หรือถูกชำระไปแล้ว) = ล้างทิ้ง ไม่ส่งค่าเก่า
        setDraft((d) => (d.clearsSourceId && !r.items.some((i) => i.id === d.clearsSourceId) ? { ...d, clearsSourceId: "" } : d));
      })
      .catch(() => live && setSources({ key: reductionKey, items: [], loading: false, error: "ติดต่อเซิร์ฟเวอร์ไม่ได้ จึงโหลดรายการค้างไม่ได้" }));
    return () => {
      live = false;
    };
  }, [reductionKey]);
  const clearSources = sources;
  /** ลดลูกหนี้/เจ้าหนี้ แต่ผู้ถือไม่มีของค้างเหลือเลย → บันทึกไม่ได้ (DB ปฏิเสธ) บอกทางออกตรงๆ */
  const clearNoSource = !!reductionKey && !sources.loading && !sources.error && sources.key === reductionKey && sources.items.length === 0;

  /** ช่องที่ยังขาด = ช่องของฟอร์ม + (มีของค้างหลายใบแต่ยังไม่เลือกใบที่ชำระ · ด่านของ DB) */
  const missing = React.useMemo(
    () =>
      clearSources.items.length > 1 && !draft.clearsSourceId
        ? [...missingBase, "ใบค้างที่ชำระ (มีของค้างหลายใบ)"]
        : missingBase,
    [missingBase, clearSources.items.length, draft.clearsSourceId]
  );

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
      buildPosting(postingInput, resolver);
      return null;
    } catch (e) {
      // ห้ามโยนต่อระหว่าง render — จอจะขาวทั้งหน้า ทั้งที่แค่กรอกยังไม่ครบ
      if (e instanceof PostingError) return e.message;
      return e instanceof Error ? e.message : String(e);
    }
  }, [postingInput, resolver]);

  // ---- tag + น้ำหนัก (ADR 0002/0003) ----
  // แค็ตตาล็อกอ่านสดจาก DB · อ่านไม่ได้/ยังไม่ได้ลง migration = บอกตรงๆ และ **ไม่ให้เลือก tag** (ไม่ใช่ซ่อนแล้วลงโดยไม่มี tag เงียบๆ)
  const canTag = permissions.has("tag.assign");
  const [tagCat, setTagCat] = React.useState<{ loading: boolean; error: string | null; notMigrated: boolean; kinds: TagKind[]; tags: Tag[]; hiddenKinds: HiddenKind[] }>({
    loading: true,
    error: null,
    notMigrated: false,
    kinds: [],
    tags: [],
    hiddenKinds: [],
  });
  React.useEffect(() => {
    if (!canTag) {
      setTagCat({ loading: false, error: null, notMigrated: false, kinds: [], tags: [], hiddenKinds: [] });
      return;
    }
    let live = true;
    loadTagCatalog()
      .then((r) => {
        if (!live) return;
        setTagCat(
          r.ok
            ? { loading: false, error: null, notMigrated: false, kinds: r.kinds, tags: r.tags, hiddenKinds: r.hiddenKinds }
            : { loading: false, error: r.message, notMigrated: r.notMigrated, kinds: [], tags: [], hiddenKinds: [] }
        );
      })
      .catch(() => live && setTagCat({ loading: false, error: "ติดต่อเซิร์ฟเวอร์ไม่ได้ จึงโหลดรายการ tag ไม่ได้", notMigrated: false, kinds: [], tags: [], hiddenKinds: [] }));
    return () => {
      live = false;
    };
  }, [canTag]);

  /** น้ำหนักที่จะส่งจริง: ตัดของ tag ที่เอาออกแล้ว + ใส่ 100% ให้ project อันเดียว (เปิดเผยในช่อง ไม่ใช่เดา) */
  const tagWeightsEffective = React.useMemo(() => {
    const chosen = tagCat.tags.filter((t) => draft.tagIds.includes(t.id));
    return withSoleTagWeight(chosen, tagCat.kinds, pruneWeights(draft.tagIds, draft.tagWeights));
  }, [tagCat.tags, tagCat.kinds, draft.tagIds, draft.tagWeights]);

  /** ตัวตรวจตัวเดียวกับที่ server action เรียก — ปุ่มบันทึกถามตัวนี้ ไม่ใช่ถามรายการช่องที่ฟอร์มรู้จัก */
  const tagCheck = React.useMemo<SelectionCheck>(() => {
    if (draft.tagIds.length === 0) return { ok: true, labelTagIds: [], tagWeights: {}, groups: [] };
    if (tagCat.loading || tagCat.error) {
      return { ok: false, issues: [tagCat.error ?? "กำลังโหลดรายการ tag — รอสักครู่"] };
    }
    return checkTagSelection({ tagIds: draft.tagIds, weights: tagWeightsEffective }, { kinds: tagCat.kinds, tags: tagCat.tags });
  }, [draft.tagIds, tagWeightsEffective, tagCat]);

  /** กดบันทึกได้ก็ต่อเมื่อกรอกครบ **และ** engine ยอมรับ **และ** ชุด tag + น้ำหนักผ่านตัวตรวจ */
  const canSubmit = missing.length === 0 && !postingError && !notWired && !clearNoSource && canPost && refState.ok && !submitting && tagCheck.ok;

  /** ยอดสุทธิที่แผงขายทรัพย์คำนวณได้ ต้องเป็นจำนวนเงินของรายการเสมอ */
  const setDerivedAmount = React.useCallback((n: number) => {
    setDraft((d) => (parseAmount(d.amount) === n ? d : { ...d, amount: n.toFixed(2) }));
  }, []);

  /**
   * กดบันทึก → server action → `fn_post_entry`
   *
   * ส่งแค่ `PostingInput` + วันที่ที่พิมพ์ — server คิดบรรทัดบัญชีใหม่ด้วย `buildPosting()` ตัวจริงเอง
   * (ไม่ส่งบรรทัดจาก browser · ไม่ส่ง draft ตรงๆ) · คืนผลให้ผู้เรียกแสดง **ห้ามกลืน error**
   * กันกดซ้ำสองชั้น: ธง `submitting` ในฟอร์ม + fingerprint ที่ DB คิดเอง (ลงซ้ำในหน้าต่างเวลา = replay)
   */
  const submit = React.useCallback(async (): Promise<PostEntryOutcome> => {
    if (submittingRef.current) return { ok: false, message: "กำลังบันทึกอยู่ — รอสักครู่ ห้ามกดซ้ำ" };
    if (!postingInput || !canSubmit) {
      return { ok: false, message: "ยังบันทึกไม่ได้ — ตรวจรายการที่ขึ้นเตือนสีแดงในหน้านี้ก่อน" };
    }
    submittingRef.current = true;
    setSubmitting(true);
    try {
      return await postEntry({
        input: postingInput,
        docDate: draft.docDate,
        // ส่งเฉพาะเมื่อเลือกไว้ (ค้างใบเดียว server ผูกให้เอง)
        clearsSourceId: reductionKey && draft.clearsSourceId ? draft.clearsSourceId : undefined,
        // เฉพาะหมวดแปลงค่า/แลกเงินตรา: ส่งแค่ "วันของอัตราที่เลือก + จำนวนเงินตรา" ที่เหลือ server อ่านจากสมุดเอง
        fx: fxKind ? fxChoiceOf(draft.fx) : undefined,
        // หมวดที่ไม่มีเงินเคลื่อนไม่ส่งวันที่เงิน (cash_date ต้องเป็น null) · ค้างรับ-ค้างจ่ายก็ไม่ส่ง
        cashDate: moneyMoved ? draft.cashDate : "",
        // ส่งเมื่อเลือก tag เท่านั้น · น้ำหนักที่ส่งคือชุดเดียวกับที่ตัวตรวจเพิ่งผ่าน (server ตรวจซ้ำอีกรอบ)
        tags: draft.tagIds.length > 0 ? { tagIds: draft.tagIds, weights: tagWeightsEffective } : undefined,
      });
    } catch (e) {
      // เครือข่ายขาด/เซิร์ฟเวอร์ล้มกลางทาง = ไม่รู้ว่ารายการถูกบันทึกหรือยัง ต้องบอกตรงๆ ไม่ใช่เดาว่าล้ม
      console.error("postEntry failed", e);
      return {
        ok: false,
        message:
          "ติดต่อเซิร์ฟเวอร์ไม่ได้ระหว่างบันทึก — ยังไม่ทราบว่ารายการถูกบันทึกหรือไม่ ให้เปิดหน้าสมุดบัญชีตรวจก่อนกดบันทึกซ้ำ",
      };
    } finally {
      submittingRef.current = false;
      setSubmitting(false);
    }
  }, [postingInput, canSubmit, draft.docDate, draft.cashDate, moneyMoved, reductionKey, draft.clearsSourceId, fxKind, draft.fx, draft.tagIds, tagWeightsEffective]);

  return {
    referenceState: refState,
    reference,
    canPost,
    notWired,
    fxKind,
    reloadFx,
    fxState: { loading: fxState.loading && fxState.key === fxKey, error: fxState.key === fxKey ? fxState.error : null, ctx: fxCtx },
    fxResult,
    moneyMoved,
    whtEligible,
    clearSources,
    clearNoSource,
    submitting,
    submit,
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
    accrualWhy,
    missing,
    reset,
    disposal,
    disposalState: { loading: disposalState.loading && disposalState.key === disposalKey, error: disposalState.key === disposalKey ? disposalState.error : null, ctx: disposalCtx, buildError: disposalBuild && !disposalBuild.ok ? disposalBuild.message : null },
    balanceMoveState: {
      loading: moveState.loading && moveState.key === moveKey,
      error: moveState.key === moveKey ? moveState.error : null,
      balanceMove,
    },
    repayment,
    transferToOwnerId,
    isCrossOwner,
    postingInput,
    postingError,
    canSubmit,
    setDerivedAmount,
    canTag,
    tagCatalog: tagCat,
    tagWeightsEffective,
    tagCheck,
  };
}

export type TxFormApi = ReturnType<typeof useTxForm>;
