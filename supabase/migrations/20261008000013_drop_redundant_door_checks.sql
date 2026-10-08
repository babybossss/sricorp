-- ============================================================
-- SRI OS · ถอด "ด่านที่ซ้ำซ้อน" ออกจากประตู fn_post_entry()
--
-- ที่มา: 20261008000012 ยกสองด่านของบรรทัดบัญชีขึ้นเป็น trigger บนตาราง
--   ข้อ 3 · คู่บัญชีต้องอยู่ในชุดที่ตารางกฎระบุ   → trg_lines_rule_coa
--   ข้อ 7 · bank_account_id ได้เฉพาะขาเงินสด 11xx → trg_lines_rule_bank_cash
--   แต่ยังคงด่านเดิมไว้ในประตู (หัวข้อ 3.2 / 3.3 ของ fn_post_entry) ด้วย
--   → **กฎเดียวกันอยู่สองที่** ซึ่งเป็นสิ่งที่โปรเจกต์นี้โดนมาตลอด (บทเรียนข้อ 5)
--   วันหนึ่งคนแก้ที่หนึ่งไม่แก้อีกที่ แล้วประตูกับ trigger จะตอบต่างกัน
--
-- ทำอะไร (ทั้งหมด create or replace → **รันซ้ำได้**):
--   1 · fn_post_entry()  — ถอดด่าน 3.2 (คู่บัญชี) และ 3.3 (bank เฉพาะขาเงินสด) ออก
--       และถอด **สำเนาคู่บัญชีระหว่างกัน** ที่พิมพ์มือไว้ในฟังก์ชันออกด้วย
--       → เหลือการอ่านจาก sri_os.fn_intercompany_coa() ที่เดียว
--   2 · fn_assert_line_coa_in_rules()  — ข้อความชี้บรรทัดที่ถูกปฏิเสธได้ชัดขึ้น
--   3 · fn_assert_line_bank_is_cash()  — เหมือนกัน (ประตูเคยบอก "บรรทัดที่ n" ได้
--       เพราะมันเห็น payload · trigger เห็นแต่แถว จึงบอก **ยอดของแถวนั้น** แทน
--       เพื่อไม่ให้คุณภาพข้อความแย่ลงหลังถอดด่านในประตู)
--   4 · guard ท้ายไฟล์ — ดังตอน migrate ถ้าด่านที่เหลืออยู่ไม่ครบ/หลวม
--
-- **สิ่งที่ "ไม่" เปลี่ยน**: กฎที่บังคับ · trigger ทั้งสองยังเป็นคนปฏิเสธเหมือนเดิม
--   และแข็งกว่าประตูเพราะกันการ INSERT ตรงเข้าตารางด้วย (บทเรียนข้อ 6)
--   ข้อความที่ผู้ใช้เห็นยังมีคำที่เดิมมี ('ตารางกฎ' · 'เฉพาะขาเงินสด') —
--   guard ท้ายไฟล์ตรวจข้อนี้ให้ ไม่ใช่ความจำของคน
--
-- สิ่งที่ยังอยู่ในประตูโดยตั้งใจ (ไม่ใช่กฎที่สอง เป็น "ด่านของข้อมูลที่ยังไม่ถูกเขียน"):
--   - หมวดที่ตารางกฎไม่ได้ระบุบัญชีไว้เลย → ปฏิเสธพร้อมบอกให้ sync (3.1)
--   - รหัสบัญชีที่ไม่มีในผังบัญชี → บอกว่าผังใน DB อาจยังไม่ sync กับ coa.ts
--   - ลักษณะข้ามผู้ถือที่ไม่รู้จัก → ข้อความภาษาคน แทน error ดิบของ check constraint
--     (อ่านรายชื่อลักษณะจาก fn_intercompany_pairs() **ไม่ใช่พิมพ์มือ**)
--   - ข้ามผู้ถือต้องมาครบคู่ในคำขอเดียว (3.4) — ด่านจริงคือ trg_intercompany_pair
--     ที่นี่ให้ข้อความที่อ่านรู้เรื่องก่อนที่อะไรจะถูกเขียน
--
-- rollback note
--   ย้อนทั้งไฟล์ = **รัน 20261008000011 ซ้ำทั้งไฟล์ แล้วรัน 20261008000012 ซ้ำทั้งไฟล์**
--   (เรียงตามนี้เท่านั้น) → ได้ fn_post_entry รุ่นที่มีด่าน 3.2/3.3 และข้อความ
--   รุ่นก่อนของ trigger ทั้งสองคืนมา · ไม่มีการแก้ข้อมูลเลย ไม่ต้องกู้อะไร
--
--   **ข้อควรรู้ของลำดับ**: guard ในไฟล์ 20261008000012 ตรวจว่า fn_post_entry
--   มีสำเนาคู่บัญชีระหว่างกันตรงกับ fn_intercompany_pairs() — ไฟล์นี้ถอดสำเนานั้นออก
--   ดังนั้น **รัน 20261008000012 ซ้ำหลังไฟล์นี้โดยไม่รัน 20261008000011 ก่อนจะล้ม**
--   (ล้มแบบปฏิเสธทั้งธุรกรรม ไม่ใช่ปล่อยกฎหลวม) · replay เรียงตามชื่อไฟล์
--   ปกติ (…011 → …012 → …013) ไม่เจอปัญหานี้
-- ============================================================

set search_path = sri_os, public;

-- ------------------------------------------------------------
-- 1 · ประตู — ถอดด่าน 3.2/3.3 และถอดสำเนาคู่บัญชีระหว่างกันออก
--     (เนื้อที่เหลือเหมือน 20261008000011 ทุกบรรทัด — คัดลอกมาเพราะไฟล์เดิมแก้ไม่ได้)
-- ------------------------------------------------------------
create or replace function fn_post_entry(p_payload jsonb) returns jsonb
language plpgsql set search_path = '' as $fn$
declare
  c_header constant text[] := array[
    'txn_type_code', 'doc_date', 'cash_date', 'doc_no', 'memo', 'attachments',
    'asset_id', 'contact_id', 'contract_id', 'owner_reason', 'funding_source',
    'source', 'source_ref', 'reverses_id', 'transactions'];
  c_txn    constant text[] := array['owner_id', 'counter_owner_id', 'intercompany_nature', 'lines'];
  c_line   constant text[] := array['coa_code', 'bank_account_id', 'asset_id',
                                    'debit', 'credit', 'cf_category', 'memo'];
  v_bad      text;
  v_source   text;
  v_has_cash boolean := false;
  v_i        int := 0;
  v_j        int;
  v_dr       numeric;
  v_cr       numeric;
  v_txn      jsonb;
  v_line     jsonb;
  v_coa      uuid;
  v_txn_id   uuid;
  v_ids      uuid[] := '{}';
  v_prev     uuid[];
  v_fp       text;
  v_canon    jsonb;
  v_secs     numeric;
  v_req      uuid;
  v_doc      date;
  v_cash     date;
  v_allowed  text[];
  v_nature   text;
begin
  -- ========== 0 · ไม่ส่งข้อมูลมาเลย = ปฏิเสธ ห้ามตกไปเส้นทางปกติ (บทเรียนข้อ 1) ==========
  if p_payload is null or jsonb_typeof(p_payload) = 'null' then
    raise exception 'บันทึกรายการไม่ได้: ไม่ได้ส่งข้อมูลรายการมาเลย';
  end if;
  if jsonb_typeof(p_payload) <> 'object' then
    raise exception 'บันทึกรายการไม่ได้: รูปแบบข้อมูลไม่ถูกต้อง — ต้องเป็น object ของทั้งใบ ไม่ใช่ %',
      jsonb_typeof(p_payload);
  end if;

  select string_agg(k, ', ' order by k) into v_bad
    from jsonb_object_keys(p_payload) as k where k <> all (c_header);
  if v_bad is not null then
    raise exception 'บันทึกรายการไม่ได้: มีช่องที่ยังไม่รู้จัก (%) — RPC ปฏิเสธทั้งใบแทนที่จะทิ้งช่องนั้นเงียบๆ · ช่องที่รับคือ %',
      v_bad, array_to_string(c_header, ', ');
  end if;

  -- ========== 1 · ผู้เรียกต้องมีตัวตนในระบบ ==========
  if auth.uid() is null then
    raise exception 'บันทึกรายการไม่ได้: ยังไม่ได้ล็อกอิน';
  end if;
  if not exists (select 1 from sri_os.app_users u where u.id = auth.uid() and u.is_active) then
    raise exception 'บันทึกรายการไม่ได้: ผู้ใช้นี้ยังไม่ได้ถูกตั้งตำแหน่งในระบบ หรือถูกปิดใช้งานแล้ว';
  end if;

  -- ========== 2 · ช่องบังคับของหัวรายการ ==========
  if nullif(p_payload ->> 'txn_type_code', '') is null then
    raise exception 'บันทึกรายการไม่ได้: ไม่ได้ส่ง txn_type_code (หมวดย่อยของรายการ)';
  end if;
  if not exists (select 1 from sri_os.txn_types t where t.code = p_payload ->> 'txn_type_code') then
    raise exception 'บันทึกรายการไม่ได้: ไม่มีหมวด "%" ในตารางกฎ (txn_types) — ตารางกฎคือแหล่งความจริงเดียว ถ้าเพิ่มหมวดใหม่ให้ sync ด้วย npm run sync:rules',
      p_payload ->> 'txn_type_code';
  end if;
  if nullif(p_payload ->> 'doc_date', '') is null then
    raise exception 'บันทึกรายการไม่ได้: ไม่ได้ส่ง doc_date (วันที่เอกสาร)';
  end if;

  -- วันที่: แปลงที่นี่ครั้งเดียว เพื่อให้ได้ข้อความภาษาคนแทน error ดิบของการ cast
  -- และเพื่อให้ "2026-09-01" กับรูปอื่นของวันเดียวกันได้ fingerprint เดียวกัน (ข้อ 4)
  begin
    v_doc := (p_payload ->> 'doc_date')::date;
  exception when others then
    raise exception 'บันทึกรายการไม่ได้: doc_date "%" ไม่ใช่วันที่ที่อ่านได้ (ต้องเป็น YYYY-MM-DD)',
      p_payload ->> 'doc_date';
  end;
  if nullif(p_payload ->> 'cash_date', '') is not null then
    begin
      v_cash := (p_payload ->> 'cash_date')::date;
    exception when others then
      raise exception 'บันทึกรายการไม่ได้: cash_date "%" ไม่ใช่วันที่ที่อ่านได้ (ต้องเป็น YYYY-MM-DD)',
        p_payload ->> 'cash_date';
    end;
  end if;

  v_source := coalesce(nullif(p_payload ->> 'source', ''), 'manual');
  if not exists (
       select 1 from pg_catalog.pg_enum e
         join pg_catalog.pg_type t on t.oid = e.enumtypid
         join pg_catalog.pg_namespace n on n.oid = t.typnamespace
        where n.nspname = 'sri_os' and t.typname = 'txn_source' and e.enumlabel = v_source) then
    raise exception 'บันทึกรายการไม่ได้: source "%" ไม่รู้จัก', v_source;
  end if;

  if p_payload -> 'attachments' is not null
     and jsonb_typeof(p_payload -> 'attachments') <> 'array' then
    raise exception 'บันทึกรายการไม่ได้: attachments ต้องเป็น array ของชื่อไฟล์';
  end if;

  if p_payload -> 'transactions' is null then
    raise exception 'บันทึกรายการไม่ได้: ไม่ได้ส่ง transactions (ผลลัพธ์จาก buildPosting)';
  end if;
  if jsonb_typeof(p_payload -> 'transactions') <> 'array' then
    raise exception 'บันทึกรายการไม่ได้: transactions ต้องเป็น array (หนึ่งสมาชิก = หนึ่งผู้ถือ)';
  end if;
  if jsonb_array_length(p_payload -> 'transactions') = 0 then
    raise exception 'บันทึกรายการไม่ได้: ไม่มีรายการใน transactions เลย';
  end if;

  -- ========== 3 · ตรวจรูปของทุกรายการ/ทุกบรรทัด **ก่อนเขียนอะไรลงไป** ==========
  for v_txn in select value from jsonb_array_elements(p_payload -> 'transactions') loop
    v_i := v_i + 1;
    if jsonb_typeof(v_txn) <> 'object' then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % ต้องเป็น object', v_i;
    end if;

    select string_agg(k, ', ' order by k) into v_bad
      from jsonb_object_keys(v_txn) as k where k <> all (c_txn);
    if v_bad is not null then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % มีช่องที่ยังไม่รู้จัก (%) · ช่องที่รับคือ %',
        v_i, v_bad, array_to_string(c_txn, ', ');
    end if;

    if nullif(v_txn ->> 'owner_id', '') is null then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % ไม่ได้ส่ง owner_id (ผู้ถือ) — หนึ่งรายการ = หนึ่งผู้ถือ เดาแทนไม่ได้', v_i;
    end if;

    -- ข้ามผู้ถือต้องมาเป็นคู่: ขาดข้างใดข้างหนึ่งแปลว่าข้อมูลไม่ครบ ไม่ใช่รายการธรรมดา
    if nullif(v_txn ->> 'counter_owner_id', '') is not null
       and nullif(v_txn ->> 'intercompany_nature', '') is null then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % เป็นรายการข้ามผู้ถือ ต้องระบุลักษณะ (intercompany_nature: advance/loan/capital/dividend)', v_i;
    end if;
    if nullif(v_txn ->> 'intercompany_nature', '') is not null
       and nullif(v_txn ->> 'counter_owner_id', '') is null then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % ระบุลักษณะข้ามผู้ถือแต่ไม่มีผู้ถืออีกฝ่าย (counter_owner_id)', v_i;
    end if;
    if nullif(v_txn ->> 'counter_owner_id', '') is not null
       and (v_txn ->> 'counter_owner_id') = (v_txn ->> 'owner_id') then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % ระบุผู้ถืออีกฝ่ายเป็นคนเดียวกับผู้ถือของรายการ — ถ้าเป็นการย้ายกระเป๋าในคนเดียวกัน ไม่ใช่รายการข้ามผู้ถือ', v_i;
    end if;

    if v_txn -> 'lines' is null or jsonb_typeof(v_txn -> 'lines') <> 'array' then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % ไม่ได้ส่ง lines เป็น array', v_i;
    end if;
    if jsonb_array_length(v_txn -> 'lines') < 2 then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % มีบรรทัดบัญชี % บรรทัด — บัญชีสองด้านต้องมีอย่างน้อยสองบรรทัด',
        v_i, jsonb_array_length(v_txn -> 'lines');
    end if;

    -- ---------- 3.1 ชุดบัญชีที่หมวดนี้ใช้ได้ — อ่านจากตารางกฎ ไม่ได้คิดเอง (ข้อ 3) ----------
    select array_remove(array[t.dr_coa_code, t.cr_coa_code, t.gain_coa_code,
                              t.loss_coa_code, t.interest_coa_code, t.accrual_coa_code], null)
      into v_allowed
      from sri_os.txn_types t where t.code = p_payload ->> 'txn_type_code';
    if v_allowed is null or cardinality(v_allowed) = 0 then
      raise exception 'บันทึกรายการไม่ได้: ตารางกฎ (txn_types) ไม่ได้ระบุบัญชีของหมวด "%" เลย — sync ด้วย npm run sync:rules ก่อน ห้ามเดาคู่บัญชีแทน',
        p_payload ->> 'txn_type_code';
    end if;

    -- ---------- 3.2 ลักษณะข้ามผู้ถือต้องเป็นลักษณะที่ฝั่ง DB รู้จัก (ห้ามเดา) ----------
    -- **ไม่มีสำเนาคู่บัญชีในฟังก์ชันนี้แล้ว** — อ่านจาก fn_intercompany_pairs() ที่เดียว
    --   ด่าน "ขาข้ามผู้ถือต้องเป็นรหัสตรงของลักษณะนั้น" อยู่ที่ trg_lines_rule_coa
    --   ที่นี่เหลือแค่การปฏิเสธลักษณะที่ไม่รู้จัก **ก่อนเขียนอะไรลงไป** เพื่อให้ได้
    --   ข้อความภาษาคน ไม่ใช่ error ดิบของ check constraint
    v_nature := nullif(v_txn ->> 'intercompany_nature', '');
    if v_nature is not null and sri_os.fn_intercompany_coa(v_nature) is null then
      raise exception 'บันทึกรายการไม่ได้: ลักษณะรายการข้ามผู้ถือ "%" ไม่รู้จัก (ที่รับคือ %)',
        v_nature,
        coalesce((select string_agg(p.nature, '/' order by p.nature)
                    from sri_os.fn_intercompany_pairs() p), '(ยังไม่มีลักษณะใดในฝั่ง DB)');
    end if;

    v_j := 0;
    for v_line in select value from jsonb_array_elements(v_txn -> 'lines') loop
      v_j := v_j + 1;
      if jsonb_typeof(v_line) <> 'object' then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % ต้องเป็น object', v_i, v_j;
      end if;

      select string_agg(k, ', ' order by k) into v_bad
        from jsonb_object_keys(v_line) as k where k <> all (c_line);
      if v_bad is not null then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % มีช่องที่ยังไม่รู้จัก (%) · ช่องที่รับคือ %',
          v_i, v_j, v_bad, array_to_string(c_line, ', ');
      end if;

      if nullif(v_line ->> 'coa_code', '') is null then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % ไม่ได้ส่ง coa_code', v_i, v_j;
      end if;
      select c.id into v_coa
        from sri_os.chart_of_accounts c where c.code = v_line ->> 'coa_code';
      if v_coa is null then
        raise exception 'บันทึกรายการไม่ได้: ไม่มีรหัส "%" ในผังบัญชี (chart_of_accounts) — ผังบัญชีในฐานข้อมูลอาจยังไม่ sync กับ src/lib/rules/coa.ts',
          v_line ->> 'coa_code';
      end if;

      if (v_line -> 'debit') is null and (v_line -> 'credit') is null then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % ไม่ได้ส่งทั้งเดบิตและเครดิต', v_i, v_j;
      end if;
      if (v_line -> 'debit') is not null and jsonb_typeof(v_line -> 'debit') not in ('number', 'null') then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % เดบิตต้องเป็นตัวเลข', v_i, v_j;
      end if;
      if (v_line -> 'credit') is not null and jsonb_typeof(v_line -> 'credit') not in ('number', 'null') then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % เครดิตต้องเป็นตัวเลข', v_i, v_j;
      end if;
      v_dr := coalesce((v_line ->> 'debit')::numeric, 0);
      v_cr := coalesce((v_line ->> 'credit')::numeric, 0);
      if v_dr < 0 or v_cr < 0 then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % มียอดติดลบ (เดบิต % เครดิต %) — ทิศทางมาจากด้านที่ลง ไม่ใช่จากเครื่องหมาย',
          v_i, v_j, v_dr, v_cr;
      end if;
      if not ((v_dr > 0 and v_cr = 0) or (v_cr > 0 and v_dr = 0)) then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % ต้องลงด้านเดียวและมากกว่า 0 (เดบิต % เครดิต %)',
          v_i, v_j, v_dr, v_cr;
      end if;

      if nullif(v_line ->> 'cf_category', '') is not null
         and not exists (
           select 1 from pg_catalog.pg_enum e
             join pg_catalog.pg_type t on t.oid = e.enumtypid
             join pg_catalog.pg_namespace n on n.oid = t.typnamespace
            where n.nspname = 'sri_os' and t.typname = 'cf_group'
              and e.enumlabel = v_line ->> 'cf_category') then
        raise exception 'บันทึกรายการไม่ได้: หมวดกระแสเงินสด "%" ไม่รู้จัก', v_line ->> 'cf_category';
      end if;

      -- ผังบัญชี 1100-1199 = เงินสดและเงินฝาก (เกณฑ์เดียวกับ fn_assert_no_floating_cash)
      if (v_line ->> 'coa_code') ~ '^11[0-9][0-9]$' then v_has_cash := true; end if;
    end loop;
  end loop;

  -- ========== 3.4 · ข้ามผู้ถือต้องมาครบคู่ในคำขอเดียว (ข้อ 2 · ข้อความที่อ่านรู้เรื่อง) ==========
  -- ด่านจริงคือ trg_intercompany_pair (constraint trigger) ที่ครอบ REST ตรงด้วย
  -- ที่นี่ตรวจซ้ำเพื่อให้ผู้กดได้ข้อความก่อนที่อะไรจะถูกเขียน ไม่ใช่กฎที่สองที่คิดต่างกัน
  with legs as (
    select (x.value ->> 'owner_id') as o,
           nullif(x.value ->> 'counter_owner_id', '') as c,
           nullif(x.value ->> 'intercompany_nature', '') as n,
           (select coalesce(sum(coalesce((l.value ->> 'debit')::numeric, 0)), 0)
              from jsonb_array_elements(x.value -> 'lines') as l) as amt
      from jsonb_array_elements(p_payload -> 'transactions') as x
  )
  select string_agg(distinct a.o, ', ') into v_bad
    from legs a
   where a.c is not null
     and (select count(*) from legs b
           where b.o = a.o and b.c = a.c and b.n = a.n and b.amt = a.amt)
      <> (select count(*) from legs b
           where b.o = a.c and b.c = a.o and b.n = a.n and b.amt = a.amt);
  if v_bad is not null then
    raise exception 'บันทึกรายการไม่ได้: รายการข้ามผู้ถือต้องมาครบคู่ในคำขอเดียว (ขาออกของผู้ถือหนึ่ง + ขาเข้าของอีกผู้ถือ ยอดเท่ากัน) — ขาของผู้ถือ % ไม่มีขาคู่ · ขาเดียวแปลว่าเงินหายไปข้างหนึ่งและงบรวมตัดรายการระหว่างกันไม่ลง',
      v_bad;
  end if;

  -- ========== 4 · cash_date ต้องสอดคล้องกับบรรทัดที่เครื่องยนต์ส่งมา ==========
  if v_has_cash and v_cash is null then
    raise exception 'บันทึกรายการไม่ได้: รายการนี้มีบรรทัดเงินสด/เงินฝาก แต่ไม่ได้ส่ง cash_date (วันที่เงินเข้า-ออกจริง) — ถ้าเงินยังไม่เคลื่อน ต้องลงเป็นลูกหนี้/เจ้าหนี้ ไม่ใช่เงินสด';
  end if;
  if not v_has_cash and v_cash is not null then
    raise exception 'บันทึกรายการไม่ได้: รายการนี้ไม่มีบรรทัดเงินสดเลย (ค้างรับ-ค้างจ่าย) cash_date ต้องเป็น null ไม่งั้นงบกระแสเงินสดจะนับเงินที่ยังไม่เคลื่อน';
  end if;

  -- ========== 5 · กันกดปุ่มซ้ำ — ล็อกแถว fingerprint ก่อนลงรายการ ==========
  select coalesce((s.value #>> '{}')::numeric, 60) into v_secs
    from sri_os.settings s where s.key = 'ledger.post_dedupe_seconds';
  v_secs := greatest(coalesce(v_secs, 60), 0);

  -- ข้อ 4: normalise ก่อนคิด fingerprint · วันที่/source ใช้ค่าที่ฟังก์ชันจะใช้จริง
  v_canon := sri_os.fn_canonical_payload(p_payload);
  v_canon := jsonb_set(v_canon, '{doc_date}', to_jsonb(v_doc::text));
  if v_cash is null then
    v_canon := v_canon - 'cash_date';
  else
    v_canon := jsonb_set(v_canon, '{cash_date}', to_jsonb(v_cash::text));
  end if;
  v_canon := jsonb_set(v_canon, '{source}', to_jsonb(v_source));

  v_fp := encode(sha256(convert_to(auth.uid()::text || '|' || v_canon::text, 'UTF8')), 'hex');

  insert into sri_os.post_entry_requests as r (fingerprint)
  values (v_fp)
      on conflict (fingerprint) do update
         set created_at = now(), transaction_ids = '{}'::uuid[]
       where r.created_at < now() - make_interval(secs => v_secs::double precision)
  returning r.id into v_req;

  if v_req is null then
    -- คำขอเดิมซ้ำในหน้าต่าง = กดรัว · คืน id ชุดเดิมโดยไม่ลงใหม่
    select r.transaction_ids into v_prev
      from sri_os.post_entry_requests r where r.fingerprint = v_fp;
    return jsonb_build_object(
      'transaction_ids', coalesce(to_jsonb(v_prev), '[]'::jsonb),
      'replayed', true,
      'fingerprint', v_fp);
  end if;

  -- ========== 6 · เขียนลงจริง — หัวรายการ + บรรทัด ในธุรกรรมเดียวกัน (D-091) ==========
  -- created_by ไม่อยู่ในรายการคอลัมน์โดยตั้งใจ: trigger ตั้งเป็น auth.uid() ให้ (ข้อ 5)
  for v_txn in select value from jsonb_array_elements(p_payload -> 'transactions') loop
    insert into sri_os.transactions (
      owner_id, txn_type_code, doc_date, cash_date, doc_no, memo, attachments,
      asset_id, contact_id, contract_id, owner_reason, funding_source,
      source, source_ref, reverses_id,
      is_intercompany, counter_owner_id, intercompany_nature)
    values (
      (v_txn ->> 'owner_id')::uuid,
      p_payload ->> 'txn_type_code',
      v_doc,
      v_cash,
      nullif(p_payload ->> 'doc_no', ''),
      nullif(p_payload ->> 'memo', ''),
      coalesce((select array_agg(a) from jsonb_array_elements_text(p_payload -> 'attachments') as a),
               '{}'::text[]),
      (nullif(p_payload ->> 'asset_id', ''))::uuid,
      (nullif(p_payload ->> 'contact_id', ''))::uuid,
      (nullif(p_payload ->> 'contract_id', ''))::uuid,
      nullif(p_payload ->> 'owner_reason', ''),
      nullif(p_payload ->> 'funding_source', ''),
      v_source::sri_os.txn_source,
      nullif(p_payload ->> 'source_ref', ''),
      (nullif(p_payload ->> 'reverses_id', ''))::uuid,
      nullif(v_txn ->> 'counter_owner_id', '') is not null,
      (nullif(v_txn ->> 'counter_owner_id', ''))::uuid,
      nullif(v_txn ->> 'intercompany_nature', ''))
    returning id into v_txn_id;

    for v_line in select value from jsonb_array_elements(v_txn -> 'lines') loop
      insert into sri_os.transaction_lines (
        transaction_id, coa_id, bank_account_id, debit, credit, cf_category, asset_id, memo)
      values (
        v_txn_id,
        (select c.id from sri_os.chart_of_accounts c where c.code = v_line ->> 'coa_code'),
        (nullif(v_line ->> 'bank_account_id', ''))::uuid,
        coalesce((v_line ->> 'debit')::numeric, 0),
        coalesce((v_line ->> 'credit')::numeric, 0),
        (nullif(v_line ->> 'cf_category', ''))::sri_os.cf_group,
        (nullif(v_line ->> 'asset_id', ''))::uuid,
        nullif(v_line ->> 'memo', ''));
    end loop;

    v_ids := v_ids || v_txn_id;
  end loop;

  update sri_os.post_entry_requests r
     set transaction_ids = v_ids
   where r.id = v_req;

  -- ด่านสมดุล/บรรทัดครบ/คู่ข้ามผู้ถือเป็น constraint trigger แบบ deferred (ยิงตอน commit)
  -- → บังคับให้ยิง **ตอนนี้** เพื่อให้คนกดปุ่มได้ข้อความที่อ่านรู้เรื่องทันที
  --   นี่คือการทำให้ด่าน **เข้มขึ้น (เร็วขึ้น)** ไม่ใช่ผ่อน · แล้วคืนสภาพ deferred ให้เหมือนเดิม
  set constraints all immediate;
  set constraints all deferred;

  return jsonb_build_object(
    'transaction_ids', to_jsonb(v_ids),
    'replayed', false,
    'fingerprint', v_fp);
end $fn$;

comment on function fn_post_entry(jsonb) is
  'ปากทางเดียวที่เขียนผลลัพธ์ของ buildPosting() ลง transactions + transaction_lines ในธุรกรรมเดียว (D-091) · **security invoker** → RLS เป็นด่านเดียว · **ไม่มีด่านคู่บัญชี/bank ซ้ำในประตูอีกแล้ว** ด่านนั้นอยู่ที่ trg_lines_rule_coa และ trg_lines_rule_bank_cash บนตาราง (กันการ INSERT ตรงด้วย) · ประตูเหลือด่านของข้อมูลที่ยังไม่ถูกเขียน: หมวดที่ตารางกฎไม่ระบุบัญชี · รหัสที่ไม่มีในผังบัญชี · ลักษณะข้ามผู้ถือที่ไม่รู้จัก (อ่านจาก fn_intercompany_pairs() ไม่มีสำเนาในฟังก์ชัน) · ข้ามผู้ถือต้องครบคู่ (ข้อ 2) · fingerprint จาก payload ที่ normalise แล้ว (ข้อ 4)';

-- ------------------------------------------------------------
-- 2 · ข้อความของ trigger — ชี้บรรทัดที่ถูกปฏิเสธให้ชัด
--
-- ประตูเคยพูดว่า "รายการที่ i บรรทัดที่ j" ได้เพราะมันเห็น payload ทั้งใบ
--   trigger เห็นแต่ **แถวที่กำลังเขียน** · transaction_lines ไม่มีเลขบรรทัด
--   (ไม่เพิ่มคอลัมน์ในไฟล์นี้: การเพิ่มคอลัมน์ให้ข้อความสวยขึ้นไม่คุ้มกับผิวสัมผัสใหม่)
--   → บอก **ยอดของแถวนั้น** แทนเลขบรรทัด ซึ่งผู้ใช้เอาไปหาในฟอร์มได้จริงกว่าเลขลำดับ
--   ตรรกะไม่เปลี่ยนแม้บรรทัดเดียว เปลี่ยนแต่ข้อความ
-- ------------------------------------------------------------
create or replace function fn_assert_line_coa_in_rules() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare
  v_type    text;
  v_nature  text;
  v_code    text;
  v_allowed text[];
  v_pair    text[];
begin
  select t.txn_type_code, nullif(t.intercompany_nature, '')
    into v_type, v_nature
    from sri_os.transactions t
   where t.id = new.transaction_id;
  if v_type is null then
    return new;   -- ไม่มีหัวรายการให้เทียบ → FK/ด่านอื่นปฏิเสธด้วยข้อความของมันเอง
  end if;

  select c.code into v_code
    from sri_os.chart_of_accounts c where c.id = new.coa_id;
  if v_code is null then
    raise exception 'บรรทัดบัญชีชี้รหัสบัญชีที่ไม่มีอยู่ในผังบัญชี (coa_id %)', new.coa_id;
  end if;

  select array_remove(array[t.dr_coa_code, t.cr_coa_code, t.gain_coa_code,
                            t.loss_coa_code, t.interest_coa_code, t.accrual_coa_code], null)
    into v_allowed
    from sri_os.txn_types t where t.code = v_type;
  if v_allowed is null or cardinality(v_allowed) = 0 then
    raise exception 'ตารางกฎ (txn_types) ไม่ได้ระบุบัญชีของหมวด "%" เลย — sync ด้วย npm run sync:rules ก่อน ห้ามเดาคู่บัญชีแทน',
      v_type;
  end if;

  if v_nature is not null then
    v_pair := sri_os.fn_intercompany_coa(v_nature);
    if v_pair is null then
      raise exception 'ลักษณะรายการข้ามผู้ถือ "%" ยังไม่มีคู่บัญชีระหว่างกันในฝั่งฐานข้อมูล — เพิ่มใน fn_intercompany_pairs() ให้ตรงกับ src/lib/rules/intercompany.ts ก่อนใช้ (ตรวจด้วย npm run check:sync)',
        v_nature;
    end if;
    -- ขาเงินสดกับ **รหัสตรง** ของลักษณะนั้นใช้ได้บนขาข้ามผู้ถือ
    v_allowed := v_allowed || array['1100'] || v_pair;
  end if;

  if not (v_code = any (v_allowed)) then
    -- แสดงรายชื่อบัญชีแบบไม่ซ้ำ: ขาเงินสด 1100 อยู่ทั้งใน dr/cr และในขาข้ามผู้ถือ
    -- ของเดิมพิมพ์ "1100, 1100, 1100, 1310, 2310" ซึ่งอ่านแล้วสับสนว่าทำไมซ้ำ
    raise exception 'หมวด "%" ลงบัญชี % ไม่ได้ — ตารางกฎระบุบัญชีของหมวดนี้ไว้เฉพาะ % · บรรทัดที่ถูกปฏิเสธ: เดบิต % เครดิต % · คู่บัญชีที่ไม่ตรงหมวดทำให้ผิดทั้งงบ (เช่น เงินกู้กลายเป็นรายได้)',
      v_type, v_code,
      (select string_agg(distinct x, ', ' order by x) from unnest(v_allowed) x),
      new.debit, new.credit;
  end if;

  return new;
end $fn$;

comment on function fn_assert_line_coa_in_rules() is
  'ข้อ 3 ของผู้ตรวจ · ทุกบรรทัดต้องใช้บัญชีที่ตารางกฎ (sri_os.txn_types) ระบุของหมวดนั้น · ขาข้ามผู้ถือล็อกเป็นรหัสตรงจาก fn_intercompany_pairs() · เทียบเป็นชุดเพื่อให้รายการกลับรายการยังลงได้ · **ที่เดียวที่บังคับกฎนี้** (ประตูไม่ตรวจซ้ำแล้ว ตั้งแต่ 20261008000013) · ข้อความบอกยอดของบรรทัดที่ถูกปฏิเสธ เพราะตารางไม่มีเลขบรรทัด';

create or replace function fn_assert_line_bank_is_cash() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare v_code text;
begin
  if new.bank_account_id is null then return new; end if;

  select c.code into v_code
    from sri_os.chart_of_accounts c where c.id = new.coa_id;
  if v_code is null then
    raise exception 'บรรทัดบัญชีชี้รหัสบัญชีที่ไม่มีอยู่ในผังบัญชี (coa_id %)', new.coa_id;
  end if;

  if v_code !~ '^11[0-9][0-9]$' then
    raise exception 'ผูกบัญชีธนาคารไว้กับบัญชี % ซึ่งไม่ใช่เงินสด/เงินฝาก (บรรทัด เดบิต % เครดิต %) — บัญชีธนาคารติดได้เฉพาะขาเงินสด (11xx) ไม่ใช่ขาลูกหนี้/เจ้าหนี้/รายได้ · ไม่งั้นกระทบยอดธนาคารจะนับบรรทัดที่เงินไม่ได้เข้าออก',
      v_code, new.debit, new.credit;
  end if;

  return new;
end $fn$;

comment on function fn_assert_line_bank_is_cash() is
  'ข้อ 7 ของผู้ตรวจ · bank_account_id อยู่ได้เฉพาะบรรทัดเงินสด 11xx · **ที่เดียวที่บังคับกฎนี้** (ประตูไม่ตรวจซ้ำแล้ว ตั้งแต่ 20261008000013) · ข้อความบอกยอดของบรรทัดที่ถูกปฏิเสธแทนเลขบรรทัด';

-- ------------------------------------------------------------
-- 3 · ACL — create or replace ไม่ล้าง ACL เดิม แต่ย้ำไว้ให้ไฟล์นี้รันเองได้
--     trigger function: ปิดทุก role (กฎเงินห้ามเรียกเอง)
-- ------------------------------------------------------------
revoke all on function fn_assert_line_coa_in_rules() from public;
revoke all on function fn_assert_line_bank_is_cash() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_assert_line_coa_in_rules() from anon, authenticated';
  execute 'revoke all on function sri_os.fn_assert_line_bank_is_cash() from anon, authenticated';
  -- ประตูเรียก fn_intercompany_coa/pairs ในฐานะผู้เรียก (invoker) → ต้องเปิดให้ authenticated
  execute 'grant execute on function sri_os.fn_intercompany_pairs() to authenticated';
  execute 'grant execute on function sri_os.fn_intercompany_coa(text) to authenticated';
  execute 'revoke all on function sri_os.fn_intercompany_pairs() from anon';
  execute 'revoke all on function sri_os.fn_intercompany_coa(text) from anon';
end $$;

-- ------------------------------------------------------------
-- 4 · guard ท้ายไฟล์ — ต้อง "พังให้เห็น" ตอน migrate
--     ไฟล์นี้ **ถอดด่าน** ออก → ถ้าด่านที่เหลือไม่ครบ ต้องไม่ยอมให้ไฟล์นี้ผ่าน
-- ------------------------------------------------------------
do $$
declare v text; n int; v_src text;
begin
  -- (ก) ด่านจริงต้องยังผูกอยู่กับตาราง ครอบทั้ง insert และ update
  --     ถ้าใครถอด trigger ไปแล้ว ไฟล์นี้จะกลายเป็นคนเปิดช่องให้เงินกู้เป็นรายได้
  foreach v in array array['fn_assert_line_coa_in_rules', 'fn_assert_line_bank_is_cash'] loop
    if not exists (select 1 from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
                    where tg.tgrelid = 'sri_os.transaction_lines'::regclass
                      and p.proname = v and not tg.tgisinternal
                      and (tg.tgtype & 1) <> 0 and (tg.tgtype & 2) <> 0
                      and (tg.tgtype & 4) <> 0 and (tg.tgtype & 16) <> 0) then
      raise exception 'ถอดด่านในประตูไม่ได้: ไม่มี trigger before insert or update for each row ที่เรียก % บน transaction_lines — ถอดแล้วจะไม่มีใครบังคับกฎนี้เลย', v;
    end if;
  end loop;

  -- (ข) คุณภาพข้อความห้ามแย่ลง — คำที่ผู้ใช้/เทสต์ใช้หาต้องยังอยู่ในด่านที่เหลือ
  select p.prosrc into v_src from pg_proc p
   where p.oid = 'sri_os.fn_assert_line_coa_in_rules()'::regprocedure;
  if v_src !~ 'ตารางกฎ' then
    raise exception 'ข้อความของ trg_lines_rule_coa ไม่มีคำว่า "ตารางกฎ" แล้ว — ประตูเคยพูดคำนี้ ถอดประตูแล้วข้อความต้องไม่แย่ลง';
  end if;
  select p.prosrc into v_src from pg_proc p
   where p.oid = 'sri_os.fn_assert_line_bank_is_cash()'::regprocedure;
  if v_src !~ 'เฉพาะขาเงินสด' then
    raise exception 'ข้อความของ trg_lines_rule_bank_cash ไม่มีคำว่า "เฉพาะขาเงินสด" แล้ว — ถอดประตูแล้วข้อความต้องไม่แย่ลง';
  end if;

  -- (ค) ประตูต้อง **ถอดด่านซ้ำออกจริง** ไม่ใช่คอมเมนต์ทิ้งไว้
  select p.prosrc into v_src from pg_proc p where p.oid = 'sri_os.fn_post_entry(jsonb)'::regprocedure;
  if v_src ~ 'ซึ่งไม่ใช่เงินสด/เงินฝาก' then
    raise exception 'ประตูยังมีด่าน bank เฉพาะขาเงินสดอยู่ — กฎเดียวกันสองที่ (บทเรียนข้อ 5)';
  end if;
  if v_src ~ 'ระบุบัญชีของหมวดนี้ไว้เฉพาะ' then
    raise exception 'ประตูยังมีด่านคู่บัญชีตรงตารางกฎอยู่ — กฎเดียวกันสองที่ (บทเรียนข้อ 5)';
  end if;

  -- (ง) และต้องไม่มี **สำเนาคู่บัญชีระหว่างกัน** พิมพ์มืออยู่ในประตูอีก
  select count(*) into n
    from regexp_matches(v_src, '''[a-z_]+''\s*,\s*''[0-9]{4}''\s*,\s*''[0-9]{4}''', 'g');
  if n > 0 then
    raise exception 'ประตูยังมีสำเนาคู่บัญชีระหว่างกันพิมพ์มืออยู่ % คู่ — ต้องอ่านจาก fn_intercompany_pairs() ที่เดียว', n;
  end if;
  if v_src !~ 'fn_intercompany_coa' then
    raise exception 'ประตูไม่ได้อ่านลักษณะข้ามผู้ถือจาก fn_intercompany_coa() — ลักษณะที่ไม่รู้จักจะหลุดไปตายที่ check constraint ด้วย error ดิบ';
  end if;

  -- (จ) ประตูต้องยังอ่านตารางกฎอยู่ (ห้ามคิดคู่บัญชีเอง = กฎที่สองทันที)
  if v_src !~ 'txn_types' then
    raise exception 'ประตูไม่ได้อ่านตารางกฎแล้ว';
  end if;

  -- (ฉ) กฎเงินห้ามขึ้นกับสิทธิ์ · definer ต้องล็อก search_path · เรียกตรงไม่ได้
  select string_agg(p.proname, ', ') into v
    from pg_proc p
   where p.oid in ('sri_os.fn_assert_line_coa_in_rules()'::regprocedure,
                   'sri_os.fn_assert_line_bank_is_cash()'::regprocedure)
     and (p.prosrc ~* 'fn_can'
       or not p.prosecdef
       or not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c
                       where c in ('search_path=', 'search_path=""', 'search_path=sri_os'))
       or has_function_privilege('public', p.oid, 'execute')
       or has_function_privilege('anon', p.oid, 'execute')
       or has_function_privilege('authenticated', p.oid, 'execute'));
  if v is not null then
    raise exception 'trigger function หลวมหรือหลวมผิดทาง (ต้อง secdef + search_path ล็อก + ไม่ถาม fn_can + เรียกตรงไม่ได้): %', v;
  end if;

  -- (ช) ประตูเป็น invoker และต้องเรียก fn_intercompany_coa ได้จริงในฐานะ authenticated
  if (select p.prosecdef from pg_proc p where p.oid = 'sri_os.fn_post_entry(jsonb)'::regprocedure) then
    raise exception 'fn_post_entry กลายเป็น security definer — RLS จะไม่ใช่ด่านเดียวอีก';
  end if;
  if not has_function_privilege('authenticated', 'sri_os.fn_intercompany_coa(text)', 'execute') then
    raise exception 'authenticated เรียก fn_intercompany_coa ไม่ได้ → ประตูจะพังทุกครั้งที่ลงรายการข้ามผู้ถือ';
  end if;

  -- (ซ) พิสูจน์ด้วยค่าจริงว่าคู่บัญชียังตอบตรงกับ src/lib/rules/intercompany.ts
  if sri_os.fn_intercompany_coa('advance')  is distinct from array['1310', '2310']
   or sri_os.fn_intercompany_coa('loan')     is distinct from array['1310', '2310']
   or sri_os.fn_intercompany_coa('capital')  is distinct from array['1710', '3100']
   or sri_os.fn_intercompany_coa('dividend') is distinct from array['3200', '4410']
   or sri_os.fn_intercompany_coa('ไม่มีจริง') is not null then
    raise exception 'fn_intercompany_coa ตอบไม่ตรงกับ src/lib/rules/intercompany.ts';
  end if;

  raise notice 'guard · ถอดด่าน 3.2/3.3 ออกจากประตูแล้ว · trigger ทั้งสองยังผูกอยู่และข้อความยังชี้จุด · ประตูไม่มีสำเนาคู่บัญชีระหว่างกันอีก';
end $$;
