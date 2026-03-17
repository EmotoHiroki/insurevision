-- =============================================
-- finalize_run() — Atomic finalize transaction
-- Implements M1 v4.1 spec Section 4, Steps 5-8
--
-- STEP 6 (run UPDATE) and STEP 7 (audit_event INSERT)
-- are strictly separated within a single transaction.
-- =============================================

CREATE OR REPLACE FUNCTION finalize_run(
    p_run_id                     uuid,
    p_pdf_object_key             text,
    p_pdf_sha256                 text,
    p_operator_id                uuid,
    p_consent_comparison_result  boolean DEFAULT false
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    -- ── STEP 6: run table UPDATE ONLY ─────────────────────────────────────
    -- No audit_event operations here. Only run fields are touched.
    UPDATE run SET
        pdf_object_key = p_pdf_object_key,
        pdf_sha256     = p_pdf_sha256,
        finalized_at   = now(),
        finalized_by   = p_operator_id,
        run_status     = 'finalized',
        export_status  = 'completed',
        updated_at     = now()
    WHERE id         = p_run_id
      AND run_status = 'draft';

    -- Guard: if the run was not in draft, abort immediately
    IF NOT FOUND THEN
        RAISE EXCEPTION 'finalize_run: run % not found or not in draft status', p_run_id;
    END IF;

    -- ── STEP 7: audit_event INSERT ONLY ───────────────────────────────────
    -- No run table operations here. Only audit_event rows are inserted.

    -- Always insert run_finalized
    INSERT INTO audit_event (run_id, event_type, operator_id, payload)
    VALUES (
        p_run_id,
        'run_finalized',
        p_operator_id,
        jsonb_build_object('finalized_at', now())
    );

    -- Conditionally insert consent_comparison_result
    IF p_consent_comparison_result THEN
        INSERT INTO audit_event (run_id, event_type, operator_id, payload)
        VALUES (
            p_run_id,
            'consent_comparison_result',
            p_operator_id,
            jsonb_build_object('obtained_at', now())
        );
    END IF;

    -- COMMIT is implicit at function end (called within caller's transaction)
END;
$$;
