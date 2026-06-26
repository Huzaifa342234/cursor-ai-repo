-- FUNCTION: provider.optim_get_risk_and_referred_pts_count(jsonb, date, date)
--
-- Optimized version aligned with provider.get_risk_and_referred_pts_count counting logic:
-- 1) Identify critical readings via patient_interactions_comp (no date filter on interactions)
-- 2) Require program enrollment and doctor_clinic_mapping on device readings
-- 3) Require patient in dim_patients (patient_clinic_mapping + doctor_clinic_mapping)
-- 4) Apply date/clinic filters only when building daily_readings
-- 5) Rolling 7-day window with >= 4 distinct reading days
-- 6) Count distinct patients per reading type category

-- DROP FUNCTION IF EXISTS provider.optim_get_risk_and_referred_pts_count(jsonb, date, date);

CREATE OR REPLACE FUNCTION provider.optim_get_risk_and_referred_pts_count(
    input_clinics_ids jsonb,
    input_start_date date,
    input_end_date date)
    RETURNS character varying
    LANGUAGE plpgsql
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
        bp_count INTEGER,
        glucose_count INTEGER,
        spo2_count INTEGER,
        weight_count INTEGER,
        other_count INTEGER,
        total_ref INTEGER,
        specialist_ref INTEGER,
        back_to_pcp_ref INTEGER
    );

    IF input_clinics_ids IS NOT NULL THEN
        INSERT INTO tmp_clinic_ids (clinic_id)
        SELECT CAST(elem::text AS BIGINT)
        FROM jsonb_array_elements(input_clinics_ids) AS elem;
    END IF;

    WITH
    dim_patients AS (
        SELECT DISTINCT
            p.id AS patientid
        FROM core.patients p
        JOIN mapping.patient_clinic_mapping pcm
            ON p.id = pcm.patient_id
            AND pcm.is_active
            AND NOT pcm.is_deleted
        JOIN mapping.doctor_clinic_mapping dcm
            ON pcm.clinic_id = dcm.clinic_id
            AND dcm.is_active
            AND NOT dcm.is_deleted
        WHERE p.is_active
            AND NOT p.is_deleted
    ),

    critical_interaction_pairs AS (
        SELECT DISTINCT
            i.patient_id,
            i.reading_id
        FROM core.patient_interactions_comp i
        WHERE i.is_active = TRUE
            AND i.is_deleted = FALSE
            AND i.is_critical = TRUE
            AND LOWER(i.risk_type) IN ('high', 'moderate')
            AND TRIM(UPPER(i.status)) != 'REJECTED'
            AND i.reading_id IS NOT NULL
    ),

    dim_device_blood_pressure_readings AS (
        SELECT DISTINCT
            p.id AS patientid,
            dcm.clinic_id,
            bpc.created_on::date AS sp_created_on,
            'Blood Pressure' AS reading_type,
            bpc.id AS reading_id
        FROM core.blood_pressure_comp bpc
        JOIN mapping.patient_devices_mapping pdm
            ON bpc.imei = pdm.imei
            AND pdm.is_active
            AND NOT pdm.is_deleted
        JOIN core.patients p
            ON pdm.patient_id = p.id
            AND p.is_active
            AND NOT p.is_deleted
        JOIN mapping.patient_program_mapping ppm
            ON p.id = ppm.patient_id
            AND ppm.is_active
            AND NOT ppm.is_deleted
        JOIN core.programs prog
            ON ppm.program_id = prog.id
            AND prog.is_active
            AND NOT prog.is_deleted
        JOIN mapping.patient_doctor_mapping pdm2
            ON p.id = pdm2.patient_id
            AND pdm2.is_active
            AND NOT pdm2.is_deleted
        JOIN mapping.doctor_clinic_mapping dcm
            ON dcm.doctor_id = pdm2.doctor_id
            AND dcm.is_active
            AND NOT dcm.is_deleted
        JOIN core.clinics c
            ON dcm.clinic_id = c.id
            AND c.is_active
            AND NOT c.is_deleted
        WHERE bpc.is_active
            AND NOT bpc.is_deleted
    ),

    dim_device_blood_sugar_readings AS (
        SELECT DISTINCT
            p.id AS patientid,
            dcm.clinic_id,
            bpc.created_on::date AS sp_created_on,
            'Blood Sugar' AS reading_type,
            bpc.id AS reading_id
        FROM core.blood_sugar_comp bpc
        JOIN mapping.patient_devices_mapping pdm
            ON bpc.imei = pdm.imei
            AND pdm.is_active
            AND NOT pdm.is_deleted
        JOIN core.patients p
            ON pdm.patient_id = p.id
            AND p.is_active
            AND NOT p.is_deleted
        JOIN mapping.patient_program_mapping ppm
            ON p.id = ppm.patient_id
            AND ppm.is_active
            AND NOT ppm.is_deleted
        JOIN core.programs prog
            ON ppm.program_id = prog.id
            AND prog.is_active
            AND NOT prog.is_deleted
        JOIN mapping.patient_doctor_mapping pdm2
            ON p.id = pdm2.patient_id
            AND pdm2.is_active
            AND NOT pdm2.is_deleted
        JOIN mapping.doctor_clinic_mapping dcm
            ON dcm.doctor_id = pdm2.doctor_id
            AND dcm.is_active
            AND NOT dcm.is_deleted
        JOIN core.clinics c
            ON dcm.clinic_id = c.id
            AND c.is_active
            AND NOT c.is_deleted
        WHERE bpc.is_active
            AND NOT bpc.is_deleted
    ),

    dim_device_ox_pulse_readings AS (
        SELECT DISTINCT
            p.id AS patientid,
            dcm.clinic_id,
            bpc.created_on::date AS sp_created_on,
            'SpO2' AS reading_type,
            bpc.id AS reading_id
        FROM core.ox_pulse_comp bpc
        JOIN mapping.patient_devices_mapping pdm
            ON bpc.imei = pdm.imei
            AND pdm.is_active
            AND NOT pdm.is_deleted
        JOIN core.patients p
            ON pdm.patient_id = p.id
            AND p.is_active
            AND NOT p.is_deleted
        JOIN mapping.patient_program_mapping ppm
            ON p.id = ppm.patient_id
            AND ppm.is_active
            AND NOT ppm.is_deleted
        JOIN core.programs prog
            ON ppm.program_id = prog.id
            AND prog.is_active
            AND NOT prog.is_deleted
        JOIN mapping.patient_doctor_mapping pdm2
            ON p.id = pdm2.patient_id
            AND pdm2.is_active
            AND NOT pdm2.is_deleted
        JOIN mapping.doctor_clinic_mapping dcm
            ON dcm.doctor_id = pdm2.doctor_id
            AND dcm.is_active
            AND NOT dcm.is_deleted
        JOIN core.clinics c
            ON dcm.clinic_id = c.id
            AND c.is_active
            AND NOT c.is_deleted
        WHERE bpc.is_active
            AND NOT bpc.is_deleted
    ),

    dim_device_peak_flows_readings AS (
        SELECT DISTINCT
            p.id AS patientid,
            dcm.clinic_id,
            bpc.created_on::date AS sp_created_on,
            'Peak Flow' AS reading_type,
            bpc.id AS reading_id
        FROM core.peak_flows_comp bpc
        JOIN mapping.patient_devices_mapping pdm
            ON bpc.imei = pdm.imei
            AND pdm.is_active
            AND NOT pdm.is_deleted
        JOIN core.patients p
            ON pdm.patient_id = p.id
            AND p.is_active
            AND NOT p.is_deleted
        JOIN mapping.patient_program_mapping ppm
            ON p.id = ppm.patient_id
            AND ppm.is_active
            AND NOT ppm.is_deleted
        JOIN core.programs prog
            ON ppm.program_id = prog.id
            AND prog.is_active
            AND NOT prog.is_deleted
        JOIN mapping.patient_doctor_mapping pdm2
            ON p.id = pdm2.patient_id
            AND pdm2.is_active
            AND NOT pdm2.is_deleted
        JOIN mapping.doctor_clinic_mapping dcm
            ON dcm.doctor_id = pdm2.doctor_id
            AND dcm.is_active
            AND NOT dcm.is_deleted
        JOIN core.clinics c
            ON dcm.clinic_id = c.id
            AND c.is_active
            AND NOT c.is_deleted
        WHERE bpc.is_active
            AND NOT bpc.is_deleted
    ),

    dim_device_pill_boxes_readings AS (
        SELECT DISTINCT
            p.id AS patientid,
            dcm.clinic_id,
            bpc.created_on::date AS sp_created_on,
            'Pill Box' AS reading_type,
            bpc.id AS reading_id
        FROM core.pill_boxes_comp bpc
        JOIN mapping.patient_devices_mapping pdm
            ON bpc.imei = pdm.imei
            AND pdm.is_active
            AND NOT pdm.is_deleted
        JOIN core.patients p
            ON pdm.patient_id = p.id
            AND p.is_active
            AND NOT p.is_deleted
        JOIN mapping.patient_program_mapping ppm
            ON p.id = ppm.patient_id
            AND ppm.is_active
            AND NOT ppm.is_deleted
        JOIN core.programs prog
            ON ppm.program_id = prog.id
            AND prog.is_active
            AND NOT prog.is_deleted
        JOIN mapping.patient_doctor_mapping pdm2
            ON p.id = pdm2.patient_id
            AND pdm2.is_active
            AND NOT pdm2.is_deleted
        JOIN mapping.doctor_clinic_mapping dcm
            ON dcm.doctor_id = pdm2.doctor_id
            AND dcm.is_active
            AND NOT dcm.is_deleted
        JOIN core.clinics c
            ON dcm.clinic_id = c.id
            AND c.is_active
            AND NOT c.is_deleted
        WHERE bpc.is_active
            AND NOT bpc.is_deleted
    ),

    dim_device_weight_readings AS (
        SELECT DISTINCT
            p.id AS patientid,
            dcm.clinic_id,
            bpc.created_on::date AS sp_created_on,
            'Weight' AS reading_type,
            bpc.id AS reading_id
        FROM core.weight_comp bpc
        JOIN mapping.patient_devices_mapping pdm
            ON bpc.imei = pdm.imei
            AND pdm.is_active
            AND NOT pdm.is_deleted
        JOIN core.patients p
            ON pdm.patient_id = p.id
            AND p.is_active
            AND NOT p.is_deleted
        JOIN mapping.patient_program_mapping ppm
            ON p.id = ppm.patient_id
            AND ppm.is_active
            AND NOT ppm.is_deleted
        JOIN core.programs prog
            ON ppm.program_id = prog.id
            AND prog.is_active
            AND NOT prog.is_deleted
        JOIN mapping.patient_doctor_mapping pdm2
            ON p.id = pdm2.patient_id
            AND pdm2.is_active
            AND NOT pdm2.is_deleted
        JOIN mapping.doctor_clinic_mapping dcm
            ON dcm.doctor_id = pdm2.doctor_id
            AND dcm.is_active
            AND NOT dcm.is_deleted
        JOIN core.clinics c
            ON dcm.clinic_id = c.id
            AND c.is_active
            AND NOT c.is_deleted
        WHERE bpc.is_active
            AND NOT bpc.is_deleted
    ),

    dim_patient_device_readings AS (
        SELECT * FROM dim_device_blood_pressure_readings
        UNION ALL
        SELECT * FROM dim_device_blood_sugar_readings
        UNION ALL
        SELECT * FROM dim_device_weight_readings
        UNION ALL
        SELECT * FROM dim_device_ox_pulse_readings
        UNION ALL
        SELECT * FROM dim_device_pill_boxes_readings
        UNION ALL
        SELECT * FROM dim_device_peak_flows_readings
    ),

    critical_readings AS (
        SELECT
            r.patientid,
            r.reading_id,
            r.reading_type,
            LOWER(r.reading_type) AS reading_type_lower,
            r.sp_created_on,
            r.clinic_id
        FROM dim_patient_device_readings r
        INNER JOIN critical_interaction_pairs cip
            ON cip.patient_id = r.patientid
            AND cip.reading_id = r.reading_id
        INNER JOIN dim_patients dp
            ON dp.patientid = r.patientid
    ),

    test_high_risk_patients_full AS (
        SELECT
            patientid,
            reading_id,
            reading_type,
            reading_type_lower,
            sp_created_on,
            clinic_id
        FROM (
            SELECT
                cr.*,
                ROW_NUMBER() OVER (
                    PARTITION BY cr.patientid, cr.reading_type, cr.reading_id
                    ORDER BY cr.sp_created_on DESC
                ) AS rn
            FROM critical_readings cr
        ) deduped
        WHERE rn = 1
    ),

    daily_readings AS (
        SELECT DISTINCT
            patientid,
            reading_type_lower AS reading_type,
            clinic_id,
            sp_created_on::date AS reading_date
        FROM test_high_risk_patients_full
        WHERE (input_start_date IS NULL OR sp_created_on::date >= input_start_date)
            AND (input_end_date IS NULL OR sp_created_on::date <= input_end_date)
            AND (
                input_clinics_ids IS NULL
                OR clinic_id IN (SELECT clinic_id FROM tmp_clinic_ids)
            )
    ),

    rolling_7_days AS (
        SELECT
            a.patientid,
            a.reading_type,
            a.clinic_id,
            a.reading_date AS window_start,
            a.reading_date + INTERVAL '6 days' AS window_end,
            COUNT(DISTINCT b.reading_date) AS days_with_readings
        FROM daily_readings a
        JOIN daily_readings b
            ON b.patientid = a.patientid
            AND b.reading_type = a.reading_type
            AND b.reading_date >= a.reading_date
            AND b.reading_date <= a.reading_date + INTERVAL '6 days'
        GROUP BY
            a.patientid,
            a.reading_type,
            a.clinic_id,
            a.reading_date
    ),

    high_risk_base AS (
        SELECT DISTINCT
            patientid,
            reading_type,
            clinic_id,
            window_start,
            window_end,
            days_with_readings
        FROM rolling_7_days
        WHERE days_with_readings >= 4
    ),

    referral_table AS (
        SELECT DISTINCT
            r.patient_id,
            CAST(TRIM(p.first_name || ' ' || p.last_name) AS VARCHAR) AS full_name,
            'Specialist Referral Request' AS referal_type,
            COALESCE(r.created_on::date, NULL) AS creation_date,
            TRIM(u_cp.first_name || ' ' || u_cp.last_name) AS referal_by,
            '-' AS reason,
            dc.clinic_id
        FROM core.doctor_specialist_detail r
        INNER JOIN mapping.patient_doctor_mapping i
            ON r.patient_id = i.patient_id
            AND i.is_active = TRUE
            AND i.is_deleted = FALSE
        INNER JOIN mapping.doctor_clinic_mapping dc
            ON i.doctor_id = dc.doctor_id
            AND dc.is_active = TRUE
            AND dc.is_deleted = FALSE
        INNER JOIN core.patients p
            ON r.patient_id = p.id
            AND p.is_active = TRUE
            AND p.is_deleted = FALSE
        JOIN auth.users_credentials uc_cp
            ON uc_cp.cognito_user_id = r.created_by
            AND uc_cp.is_active = TRUE
            AND uc_cp.is_deleted = FALSE
        JOIN auth.users u_cp
            ON u_cp.id = uc_cp.user_id
            AND u_cp.is_active = TRUE
            AND u_cp.is_deleted = FALSE
        WHERE r.is_active = TRUE
            AND r.is_deleted = FALSE

        UNION ALL

        SELECT DISTINCT
            r.patient_id,
            CAST(TRIM(p.first_name || ' ' || p.last_name) AS VARCHAR) AS full_name,
            'Referred Back to PCP' AS referal_type,
            COALESCE(r.created_on::date, NULL) AS creation_date,
            TRIM(u_cp.first_name || ' ' || u_cp.last_name) AS referal_by,
            '-' AS reason,
            dc.clinic_id
        FROM core.referred_to_pcp r
        INNER JOIN mapping.patient_doctor_mapping i
            ON r.patient_id = i.patient_id
            AND i.is_active = TRUE
            AND i.is_deleted = FALSE
        INNER JOIN mapping.doctor_clinic_mapping dc
            ON i.doctor_id = dc.doctor_id
            AND dc.is_active = TRUE
            AND dc.is_deleted = FALSE
        INNER JOIN core.patients p
            ON r.patient_id = p.id
            AND p.is_active = TRUE
            AND p.is_deleted = FALSE
        JOIN auth.users_credentials uc_cp
            ON uc_cp.cognito_user_id = r.created_by
            AND uc_cp.is_active = TRUE
            AND uc_cp.is_deleted = FALSE
        JOIN auth.users u_cp
            ON u_cp.id = uc_cp.user_id
            AND u_cp.is_active = TRUE
            AND u_cp.is_deleted = FALSE
        WHERE r.is_active = TRUE
            AND r.is_deleted = FALSE
    ),

    referral_counts AS (
        SELECT
            COALESCE(SUM(CASE WHEN patient_id IS NOT NULL THEN 1 ELSE 0 END), 0) AS total_count,
            COALESCE(SUM(CASE WHEN referal_type = 'Specialist Referral Request' THEN 1 ELSE 0 END), 0) AS specialist_count,
            COALESCE(SUM(CASE WHEN referal_type = 'Referred Back to PCP' THEN 1 ELSE 0 END), 0) AS back_to_pcp_count
        FROM referral_table
        WHERE (input_start_date IS NULL OR creation_date::date >= input_start_date)
            AND (input_end_date IS NULL OR creation_date::date <= input_end_date)
            AND (
                input_clinics_ids IS NULL
                OR clinic_id IN (SELECT clinic_id FROM tmp_clinic_ids)
            )
    ),

    high_risk_counts AS (
        SELECT
            COALESCE(COUNT(DISTINCT CASE WHEN hrb.reading_type = 'blood pressure' THEN hrb.patientid END), 0) AS bp_count,
            COALESCE(COUNT(DISTINCT CASE WHEN hrb.reading_type = 'blood sugar' THEN hrb.patientid END), 0) AS glucose_count,
            COALESCE(COUNT(DISTINCT CASE WHEN hrb.reading_type = 'spo2' THEN hrb.patientid END), 0) AS spo2_count,
            COALESCE(COUNT(DISTINCT CASE WHEN hrb.reading_type = 'weight' THEN hrb.patientid END), 0) AS weight_count,
            COALESCE(COUNT(DISTINCT CASE
                WHEN hrb.reading_type NOT IN ('blood pressure', 'blood sugar', 'spo2', 'weight')
                    AND hrb.reading_type IS NOT NULL
                THEN hrb.patientid
            END), 0) AS other_count,
            MAX(rc.total_count) AS total_ref,
            MAX(rc.specialist_count) AS specialist_ref,
            MAX(rc.back_to_pcp_count) AS back_to_pcp_ref
        FROM high_risk_base hrb
        CROSS JOIN referral_counts rc
    )

    INSERT INTO tmp_high_risk_counts
    SELECT
        bp_count,
        glucose_count,
        spo2_count,
        weight_count,
        other_count,
        total_ref,
        specialist_ref,
        back_to_pcp_ref
    FROM high_risk_counts;

    SELECT
        bp_count,
        glucose_count,
        spo2_count,
        weight_count,
        other_count,
        total_ref,
        specialist_ref,
        back_to_pcp_ref
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

    referred_patients_urgent_care_type_count := 0;
    referred_patients_resource_referral_count := 0;

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
