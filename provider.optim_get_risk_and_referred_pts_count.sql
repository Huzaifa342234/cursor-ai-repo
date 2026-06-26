-- FUNCTION: provider.optim_get_risk_and_referred_pts_count(jsonb, date, date)
--
-- The high-risk counts (bp, glucose, spo2, weight, other) are computed using the
-- exact same logic as the detail functions so the patient counts always match:
--   provider.get_high_risk_bp     -> high_risk_patients_bp_count
--   provider.get_high_risk_bs     -> high_risk_patients_glucose_count
--   provider.get_high_risk_ox     -> high_risk_patients_spo2_count
--   provider.get_high_risk_weight -> high_risk_patients_weight_count
--
-- A reading is "critical" when it has a matching critical interaction
-- (is_critical, risk_type high/moderate, status != REJECTED, active) whose
-- notes are NOT NULL. Readings are sourced through patient_clinic_mapping ->
-- core.clinics (active), filtered only by the reading date, and a patient is
-- "high risk" for a reading type when they have >= 4 distinct critical reading
-- days within a rolling 7-day window.

-- DROP FUNCTION IF EXISTS provider.optim_get_risk_and_referred_pts_count(jsonb, date, date);

CREATE OR REPLACE FUNCTION provider.optim_get_risk_and_referred_pts_count(
	input_clinics_ids jsonb,
	input_start_date date,
	input_end_date date)
    RETURNS character varying
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    high_risk_patients_bp_count INTEGER := 0;
    high_risk_patients_glucose_count INTEGER := 0;
    high_risk_patients_spo2_count INTEGER := 0;
    high_risk_patients_weight_count INTEGER := 0;
    high_risk_patients_other_risk_count INTEGER := 0;

    referred_patients_total_count INTEGER := 0;
    referred_patients_urgent_care_type_count INTEGER := 0;
    referred_patients_back_to_pcp_count INTEGER := 0;
    referred_patients_specialist_by_count INTEGER := 0;
    referred_patients_resource_referral_count INTEGER := 0;

    output_json_text character varying(65535);

BEGIN
    DROP TABLE IF EXISTS tmp_clinic_ids;
    DROP TABLE IF EXISTS tmp_high_risk_counts;

    CREATE TEMP TABLE tmp_clinic_ids (
        clinic_id BIGINT
    );

    CREATE TEMP TABLE tmp_high_risk_counts (
        bp_count      INTEGER,
        glucose_count INTEGER,
        spo2_count    INTEGER,
        weight_count  INTEGER,
        other_count   INTEGER,
        total_ref     INTEGER,
        specialist_ref    INTEGER,
        back_to_pcp_ref   INTEGER
    );

    IF input_clinics_ids IS NOT NULL THEN
        INSERT INTO tmp_clinic_ids (clinic_id)
        SELECT CAST(elem::text AS BIGINT)
        FROM jsonb_array_elements(input_clinics_ids) AS elem;
    END IF;

    WITH
    -- Critical readings per type, replicating the get_high_risk_* detail functions:
    --   device reading -> patient_devices_mapping -> patients
    --                  -> patient_clinic_mapping -> core.clinics (active)
    --   INNER JOIN to a critical interaction (notes IS NOT NULL) on reading_id
    --   filtered by the reading date and the requested clinics.
    critical_readings AS (
        -- Blood Pressure
        SELECT
            p.id AS patient_id,
            c.id AS clinic_id,
            bpc.created_on::date AS reading_date,
            'blood pressure' AS reading_type
        FROM core.blood_pressure_comp bpc
        JOIN mapping.patient_devices_mapping pdm
            ON bpc.imei = pdm.imei
            AND pdm.is_active AND NOT pdm.is_deleted
        JOIN core.patients p
            ON p.id = pdm.patient_id
            AND p.is_active AND NOT p.is_deleted
        JOIN mapping.patient_clinic_mapping pcm
            ON pcm.patient_id = p.id
            AND pcm.is_active AND NOT pcm.is_deleted
        JOIN core.clinics c
            ON c.id = pcm.clinic_id
            AND c.is_active AND NOT c.is_deleted
        JOIN core.patient_interactions_comp i
            ON i.patient_id = p.id
            AND i.reading_id = bpc.id
            AND i.is_critical = true
            AND LOWER(i.risk_type) IN ('high', 'moderate')
            AND TRIM(UPPER(i.status)) != 'REJECTED'
            AND i.is_active AND NOT i.is_deleted
            AND i.notes IS NOT NULL
        WHERE bpc.is_active AND NOT bpc.is_deleted
            AND (input_clinics_ids IS NULL OR c.id IN (SELECT clinic_id FROM tmp_clinic_ids))
            AND (input_start_date IS NULL OR bpc.created_on::date >= input_start_date)
            AND (input_end_date IS NULL OR bpc.created_on::date <= input_end_date)

        UNION ALL

        -- Blood Sugar
        SELECT
            p.id,
            c.id,
            bpc.created_on::date,
            'blood sugar'
        FROM core.blood_sugar_comp bpc
        JOIN mapping.patient_devices_mapping pdm
            ON bpc.imei = pdm.imei
            AND pdm.is_active AND NOT pdm.is_deleted
        JOIN core.patients p
            ON p.id = pdm.patient_id
            AND p.is_active AND NOT p.is_deleted
        JOIN mapping.patient_clinic_mapping pcm
            ON pcm.patient_id = p.id
            AND pcm.is_active AND NOT pcm.is_deleted
        JOIN core.clinics c
            ON c.id = pcm.clinic_id
            AND c.is_active AND NOT c.is_deleted
        JOIN core.patient_interactions_comp i
            ON i.patient_id = p.id
            AND i.reading_id = bpc.id
            AND i.is_critical = true
            AND LOWER(i.risk_type) IN ('high', 'moderate')
            AND TRIM(UPPER(i.status)) != 'REJECTED'
            AND i.is_active AND NOT i.is_deleted
            AND i.notes IS NOT NULL
        WHERE bpc.is_active AND NOT bpc.is_deleted
            AND (input_clinics_ids IS NULL OR c.id IN (SELECT clinic_id FROM tmp_clinic_ids))
            AND (input_start_date IS NULL OR bpc.created_on::date >= input_start_date)
            AND (input_end_date IS NULL OR bpc.created_on::date <= input_end_date)

        UNION ALL

        -- SpO2 / Ox Pulse
        SELECT
            p.id,
            c.id,
            bpc.created_on::date,
            'spo2'
        FROM core.ox_pulse_comp bpc
        JOIN mapping.patient_devices_mapping pdm
            ON bpc.imei = pdm.imei
            AND pdm.is_active AND NOT pdm.is_deleted
        JOIN core.patients p
            ON p.id = pdm.patient_id
            AND p.is_active AND NOT p.is_deleted
        JOIN mapping.patient_clinic_mapping pcm
            ON pcm.patient_id = p.id
            AND pcm.is_active AND NOT pcm.is_deleted
        JOIN core.clinics c
            ON c.id = pcm.clinic_id
            AND c.is_active AND NOT c.is_deleted
        JOIN core.patient_interactions_comp i
            ON i.patient_id = p.id
            AND i.reading_id = bpc.id
            AND i.is_critical = true
            AND LOWER(i.risk_type) IN ('high', 'moderate')
            AND TRIM(UPPER(i.status)) != 'REJECTED'
            AND i.is_active AND NOT i.is_deleted
            AND i.notes IS NOT NULL
        WHERE bpc.is_active AND NOT bpc.is_deleted
            AND (input_clinics_ids IS NULL OR c.id IN (SELECT clinic_id FROM tmp_clinic_ids))
            AND (input_start_date IS NULL OR bpc.created_on::date >= input_start_date)
            AND (input_end_date IS NULL OR bpc.created_on::date <= input_end_date)

        UNION ALL

        -- Weight
        SELECT
            p.id,
            c.id,
            bpc.created_on::date,
            'weight'
        FROM core.weight_comp bpc
        JOIN mapping.patient_devices_mapping pdm
            ON bpc.imei = pdm.imei
            AND pdm.is_active AND NOT pdm.is_deleted
        JOIN core.patients p
            ON p.id = pdm.patient_id
            AND p.is_active AND NOT p.is_deleted
        JOIN mapping.patient_clinic_mapping pcm
            ON pcm.patient_id = p.id
            AND pcm.is_active AND NOT pcm.is_deleted
        JOIN core.clinics c
            ON c.id = pcm.clinic_id
            AND c.is_active AND NOT c.is_deleted
        JOIN core.patient_interactions_comp i
            ON i.patient_id = p.id
            AND i.reading_id = bpc.id
            AND i.is_critical = true
            AND LOWER(i.risk_type) IN ('high', 'moderate')
            AND TRIM(UPPER(i.status)) != 'REJECTED'
            AND i.is_active AND NOT i.is_deleted
            AND i.notes IS NOT NULL
        WHERE bpc.is_active AND NOT bpc.is_deleted
            AND (input_clinics_ids IS NULL OR c.id IN (SELECT clinic_id FROM tmp_clinic_ids))
            AND (input_start_date IS NULL OR bpc.created_on::date >= input_start_date)
            AND (input_end_date IS NULL OR bpc.created_on::date <= input_end_date)

        UNION ALL

        -- Peak Flow (contributes to the "other" risk bucket)
        SELECT
            p.id,
            c.id,
            bpc.created_on::date,
            'peak flow'
        FROM core.peak_flows_comp bpc
        JOIN mapping.patient_devices_mapping pdm
            ON bpc.imei = pdm.imei
            AND pdm.is_active AND NOT pdm.is_deleted
        JOIN core.patients p
            ON p.id = pdm.patient_id
            AND p.is_active AND NOT p.is_deleted
        JOIN mapping.patient_clinic_mapping pcm
            ON pcm.patient_id = p.id
            AND pcm.is_active AND NOT pcm.is_deleted
        JOIN core.clinics c
            ON c.id = pcm.clinic_id
            AND c.is_active AND NOT c.is_deleted
        JOIN core.patient_interactions_comp i
            ON i.patient_id = p.id
            AND i.reading_id = bpc.id
            AND i.is_critical = true
            AND LOWER(i.risk_type) IN ('high', 'moderate')
            AND TRIM(UPPER(i.status)) != 'REJECTED'
            AND i.is_active AND NOT i.is_deleted
            AND i.notes IS NOT NULL
        WHERE bpc.is_active AND NOT bpc.is_deleted
            AND (input_clinics_ids IS NULL OR c.id IN (SELECT clinic_id FROM tmp_clinic_ids))
            AND (input_start_date IS NULL OR bpc.created_on::date >= input_start_date)
            AND (input_end_date IS NULL OR bpc.created_on::date <= input_end_date)

        UNION ALL

        -- Pill Box (contributes to the "other" risk bucket)
        SELECT
            p.id,
            c.id,
            bpc.created_on::date,
            'pill box'
        FROM core.pill_boxes_comp bpc
        JOIN mapping.patient_devices_mapping pdm
            ON bpc.imei = pdm.imei
            AND pdm.is_active AND NOT pdm.is_deleted
        JOIN core.patients p
            ON p.id = pdm.patient_id
            AND p.is_active AND NOT p.is_deleted
        JOIN mapping.patient_clinic_mapping pcm
            ON pcm.patient_id = p.id
            AND pcm.is_active AND NOT pcm.is_deleted
        JOIN core.clinics c
            ON c.id = pcm.clinic_id
            AND c.is_active AND NOT c.is_deleted
        JOIN core.patient_interactions_comp i
            ON i.patient_id = p.id
            AND i.reading_id = bpc.id
            AND i.is_critical = true
            AND LOWER(i.risk_type) IN ('high', 'moderate')
            AND TRIM(UPPER(i.status)) != 'REJECTED'
            AND i.is_active AND NOT i.is_deleted
            AND i.notes IS NOT NULL
        WHERE bpc.is_active AND NOT bpc.is_deleted
            AND (input_clinics_ids IS NULL OR c.id IN (SELECT clinic_id FROM tmp_clinic_ids))
            AND (input_start_date IS NULL OR bpc.created_on::date >= input_start_date)
            AND (input_end_date IS NULL OR bpc.created_on::date <= input_end_date)
    ),

    -- One row per patient / reading type / day (mirrors daily_critical).
    daily_critical AS (
        SELECT DISTINCT
            patient_id,
            reading_type,
            reading_date
        FROM critical_readings
    ),

    -- Rolling 7-day windows; count distinct critical reading days per window.
    rolling_7_days AS (
        SELECT
            a.patient_id,
            a.reading_type,
            a.reading_date,
            COUNT(DISTINCT b.reading_date) AS days_with_readings
        FROM daily_critical a
        JOIN daily_critical b
            ON b.patient_id = a.patient_id
            AND b.reading_type = a.reading_type
            AND b.reading_date >= a.reading_date
            AND b.reading_date <= a.reading_date + INTERVAL '6 days'
        GROUP BY a.patient_id, a.reading_type, a.reading_date
    ),

    -- A patient is high risk for a reading type when any window has >= 4 days.
    high_risk_base AS (
        SELECT DISTINCT
            patient_id,
            reading_type
        FROM rolling_7_days
        WHERE days_with_readings >= 4
    ),

    -- Referral counts (unchanged logic).
    referral_data AS (
        -- Specialist Referrals
        SELECT DISTINCT
            r.patient_id,
            'Specialist Referral Request' AS referral_type,
            r.created_on::DATE AS creation_date,
            dc.clinic_id
        FROM core.doctor_specialist_detail r
        INNER JOIN mapping.patient_doctor_mapping i
            ON r.patient_id = i.patient_id
            AND i.is_active = true
            AND i.is_deleted = false
        INNER JOIN mapping.doctor_clinic_mapping dc
            ON i.doctor_id = dc.doctor_id
            AND dc.is_active = true
            AND dc.is_deleted = false
        WHERE r.is_active = true
            AND r.is_deleted = false
            AND (input_start_date IS NULL OR r.created_on::DATE >= input_start_date)
            AND (input_end_date IS NULL OR r.created_on::DATE <= input_end_date)
            AND (input_clinics_ids IS NULL OR dc.clinic_id = ANY(SELECT clinic_id FROM tmp_clinic_ids))

        UNION ALL

        -- PCP Referrals
        SELECT DISTINCT
            r.patient_id,
            'Referred Back to PCP' AS referral_type,
            r.created_on::DATE AS creation_date,
            dc.clinic_id
        FROM core.referred_to_pcp r
        INNER JOIN mapping.patient_doctor_mapping i
            ON r.patient_id = i.patient_id
            AND i.is_active = true
            AND i.is_deleted = false
        INNER JOIN mapping.doctor_clinic_mapping dc
            ON i.doctor_id = dc.doctor_id
            AND dc.is_active = true
            AND dc.is_deleted = false
        WHERE r.is_active = true
            AND r.is_deleted = false
            AND (input_start_date IS NULL OR r.created_on::DATE >= input_start_date)
            AND (input_end_date IS NULL OR r.created_on::DATE <= input_end_date)
            AND (input_clinics_ids IS NULL OR dc.clinic_id = ANY(SELECT clinic_id FROM tmp_clinic_ids))
    ),

    referral_counts AS (
        SELECT
            COALESCE(COUNT(patient_id), 0) AS total_count,
            COALESCE(COUNT(CASE WHEN referral_type = 'Specialist Referral Request' THEN patient_id END), 0) AS specialist_count,
            COALESCE(COUNT(CASE WHEN referral_type = 'Referred Back to PCP' THEN patient_id END), 0) AS back_to_pcp_count
        FROM referral_data
    ),

    high_risk_counts AS (
        SELECT
            COALESCE(COUNT(DISTINCT CASE WHEN reading_type = 'blood pressure' THEN patient_id END), 0) AS bp_count,
            COALESCE(COUNT(DISTINCT CASE WHEN reading_type = 'blood sugar' THEN patient_id END), 0) AS glucose_count,
            COALESCE(COUNT(DISTINCT CASE WHEN reading_type = 'spo2' THEN patient_id END), 0) AS spo2_count,
            COALESCE(COUNT(DISTINCT CASE WHEN reading_type = 'weight' THEN patient_id END), 0) AS weight_count,
            COALESCE(COUNT(DISTINCT CASE WHEN reading_type NOT IN ('blood pressure','blood sugar','spo2','weight')
                                        AND reading_type IS NOT NULL THEN patient_id END), 0) AS other_count,
            (SELECT total_count FROM referral_counts) AS total_ref,
            (SELECT specialist_count FROM referral_counts) AS specialist_ref,
            (SELECT back_to_pcp_count FROM referral_counts) AS back_to_pcp_ref
        FROM high_risk_base hrb
    )

    INSERT INTO tmp_high_risk_counts
    SELECT
        bp_count, glucose_count, spo2_count, weight_count, other_count,
        total_ref, specialist_ref, back_to_pcp_ref
    FROM high_risk_counts;

    SELECT
        bp_count, glucose_count, spo2_count, weight_count, other_count,
        total_ref, specialist_ref, back_to_pcp_ref
    INTO
        high_risk_patients_bp_count,
        high_risk_patients_glucose_count,
        high_risk_patients_spo2_count,
        high_risk_patients_weight_count,
        high_risk_patients_other_risk_count,
        referred_patients_total_count,
        referred_patients_specialist_by_count,
        referred_patients_back_to_pcp_count
    FROM tmp_high_risk_counts;

    -- These values are always 0 in the original
    referred_patients_urgent_care_type_count := 0;
    referred_patients_resource_referral_count := 0;

    -- Build JSON output
    output_json_text :=
        '{' ||
        '"high_risk_patients_bp_count": ' || high_risk_patients_bp_count || ',' ||
        '"high_risk_patients_glucose_count": ' || high_risk_patients_glucose_count || ',' ||
        '"high_risk_patients_spo2_count": ' || high_risk_patients_spo2_count || ',' ||
        '"high_risk_patients_weight_count": ' || high_risk_patients_weight_count || ',' ||
        '"high_risk_patients_other_risk_count": ' || high_risk_patients_other_risk_count || ',' ||
        '"referred_patients_total_count": ' || referred_patients_total_count || ',' ||
        '"referred_patients_urgent_care_type_count": ' || referred_patients_urgent_care_type_count || ',' ||
        '"referred_patients_back_to_pcp_count": ' || referred_patients_back_to_pcp_count || ',' ||
        '"referred_patients_specialist_by_count": ' || referred_patients_specialist_by_count || ',' ||
        '"referred_patients_resource_referral_count": ' || referred_patients_resource_referral_count ||
        '}';

    RETURN output_json_text;

EXCEPTION
    WHEN OTHERS THEN
        output_json_text :=
    	'{' ||
    	'"error": "Procedure failed: ' || REPLACE(SQLERRM, '"', '''') || '"}';
		RETURN output_json_text;
END;
$BODY$;

ALTER FUNCTION provider.optim_get_risk_and_referred_pts_count(jsonb, date, date)
    OWNER TO postgres;
