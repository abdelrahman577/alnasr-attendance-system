DROP PACKAGE MAS_FING.EMPLOYEE_ABSENCE_MANAGER;

CREATE OR REPLACE PACKAGE MAS_FING.employee_absence_manager IS

 
    TYPE excuse_set_tab IS TABLE OF VARCHAR2(30) INDEX BY VARCHAR2(20);
    TYPE holiday_set_tab IS TABLE OF BOOLEAN INDEX BY VARCHAR2(8);
    
    -- ? الأنواع الأساسية (لو مش موجودة في الـ Spec)
    TYPE absence_record IS RECORD (
        employee_code    NUMBER,
        employee_name    VARCHAR2(100),
        attendance_date  DATE,
        absence_type     VARCHAR2(30),
        absence_reason   VARCHAR2(200),
        source_system    VARCHAR2(50),
        is_excused       CHAR(1),
        excuse_type      VARCHAR2(30),
        department_name  VARCHAR2(200),
        additional_notes VARCHAR2(400)
    );
    
    TYPE absence_table IS TABLE OF absence_record INDEX BY PLS_INTEGER;
    
    TYPE emp_code_list IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    TYPE emp_name_list IS TABLE OF VARCHAR2(100) INDEX BY PLS_INTEGER;
    TYPE dept_name_list IS TABLE OF VARCHAR2(200) INDEX BY PLS_INTEGER;
    
    -- ========================================================================
    -- ? المتغيرات العامة
    -- ========================================================================
    g_work_date DATE;
    g_debug_mode BOOLEAN := FALSE;
    
    -- ========================================================================
    -- ? الإجراءات
    -- ========================================================================
    PROCEDURE log_processing_step(
        p_step_name VARCHAR2,
        p_log_message VARCHAR2,
        p_employee_code NUMBER DEFAULT NULL
    );
    
    FUNCTION is_weekend(p_date DATE) RETURN BOOLEAN;
    FUNCTION is_official_holiday(p_work_date DATE) RETURN BOOLEAN;
    FUNCTION load_holiday_set(p_from_date DATE, p_to_date DATE) RETURN holiday_set_tab;
    FUNCTION is_employee_active(p_employee_code NUMBER) RETURN BOOLEAN;
    FUNCTION has_previous_attendance_record(p_employee_code NUMBER) RETURN BOOLEAN;
    FUNCTION get_employee_department_name(p_employee_code NUMBER) RETURN VARCHAR2;
    
    PROCEDURE load_active_employees;
    PROCEDURE detect_absent_employees;
    PROCEDURE apply_all_excuses;
    
    -- ? إجراءات فردية (للتوافق)
    PROCEDURE apply_vacation_excuse;
    PROCEDURE apply_mission_excuse;
    PROCEDURE apply_permission_excuse;
    PROCEDURE apply_infect_work_excuse;
    PROCEDURE apply_training_excuse;
    PROCEDURE apply_invt_ill_excuse;
    PROCEDURE apply_military_excuse;
    PROCEDURE apply_emergency_leave_excuse;
    
    PROCEDURE exclude_night_shift_employees;
    PROCEDURE handle_half_day_attendance;
    PROCEDURE bulk_insert_absence_records(p_absence_list IN absence_table);
    PROCEDURE insert_absence_records;
    PROCEDURE bulk_insert_abs;
    
    PROCEDURE apply_manual_absence_record(
        p_employee_code NUMBER,
        p_absence_type VARCHAR2,
        p_absence_reason VARCHAR2
    );
    
    PROCEDURE generate_daily_absence_report(p_report_date DATE);
    
    PROCEDURE generate_absence_report_range(
        p_start_date DATE,
        p_end_date DATE
    );
    
    PROCEDURE load_absences_to_temp(
        p_from_date DATE,
        p_to_date DATE
    );
    
END employee_absence_manager;
/
DROP PACKAGE BODY MAS_FING.EMPLOYEE_ABSENCE_MANAGER;

CREATE OR REPLACE PACKAGE BODY MAS_FING.employee_absence_manager IS

    -- ========================================================================
    -- ? المتغيرات العامة (بدون constructor — Associative Array)
    -- ========================================================================
    v_emp_codes          emp_code_list;
    v_emp_names          emp_name_list;
    v_emp_departments    dept_name_list;

    v_absence_list       absence_table;
    v_temp_absence_list  absence_table;
    v_excuse_map         excuse_set_tab;

    -- ========================================================================
    -- LOGGING
    -- ========================================================================
    PROCEDURE log_processing_step(
        p_step_name     VARCHAR2,
        p_log_message   VARCHAR2,
        p_employee_code NUMBER DEFAULT NULL
    ) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
        v_formatted_message VARCHAR2(4000);
    BEGIN
        v_formatted_message := SUBSTR(p_log_message, 1, 3900);

        IF g_debug_mode THEN
            DBMS_OUTPUT.PUT_LINE(
                '[' || TO_CHAR(SYSDATE, 'HH24:MI:SS') || '][' ||
                p_step_name || '] ' || v_formatted_message ||
                CASE WHEN p_employee_code IS NOT NULL
                     THEN ' | Employee: ' || p_employee_code
                     ELSE '' END
            );
        END IF;

        BEGIN
            INSERT INTO att_system_logs (
                log_id, package_name, step_name, log_message,
                emp_code, log_date, log_level
            ) VALUES (
                log_seq.NEXTVAL, 'EMPLOYEE_ABSENCE_MANAGER', p_step_name,
                v_formatted_message, p_employee_code, SYSDATE, 'INFO'
            );
            COMMIT;
        EXCEPTION
            WHEN OTHERS THEN NULL;
        END;
    END log_processing_step;

    -- ========================================================================
    -- HELPER FUNCTIONS
    -- ========================================================================
    FUNCTION is_weekend(p_date DATE) RETURN BOOLEAN IS
    BEGIN
        RETURN TO_CHAR(p_date, 'DY', 'NLS_DATE_LANGUAGE=ENGLISH') IN ('FRI', 'SAT');
    END is_weekend;

    FUNCTION is_official_holiday(p_work_date DATE) RETURN BOOLEAN IS
        v_count NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_count
        FROM   emp_official_holidays
        WHERE  p_work_date BETWEEN start_date AND end_date
        AND    audit_flag = 1;

        RETURN (v_count > 0);
    EXCEPTION
        WHEN OTHERS THEN
            log_processing_step('OFFICIAL_HOLIDAY_CHECK_ERROR', 'Error: ' || SQLERRM);
            RETURN FALSE;
    END is_official_holiday;

    FUNCTION load_holiday_set(p_from_date DATE, p_to_date DATE) RETURN holiday_set_tab IS
        v_set holiday_set_tab;
        v_key VARCHAR2(8);
    BEGIN
        FOR rec IN (
            SELECT DISTINCT TRUNC(h.start_date) + lvl - 1 AS holiday_date
            FROM   emp_official_holidays h,
                   (SELECT LEVEL lvl FROM dual CONNECT BY LEVEL <= 400) l
            WHERE  h.audit_flag = 1
            AND    h.start_date <= TRUNC(p_to_date)
            AND    h.end_date   >= TRUNC(p_from_date)
            AND    TRUNC(h.start_date) + lvl - 1 BETWEEN h.start_date AND h.end_date
            AND    TRUNC(h.start_date) + lvl - 1 BETWEEN TRUNC(p_from_date) AND TRUNC(p_to_date)
        ) LOOP
            v_key := TO_CHAR(rec.holiday_date, 'YYYYMMDD');
            v_set(v_key) := TRUE;
        END LOOP;
        RETURN v_set;
    EXCEPTION
        WHEN OTHERS THEN
            log_processing_step('LOAD_HOLIDAY_SET_ERROR', 'Could not preload holidays: ' || SQLERRM);
            RETURN v_set;
    END load_holiday_set;

    FUNCTION is_employee_active(p_employee_code NUMBER) RETURN BOOLEAN IS
        v_emp_count NUMBER;
    BEGIN
        SELECT 1 INTO v_emp_count FROM emp_master WHERE employee_no = p_employee_code;
        RETURN (v_emp_count > 0);
    EXCEPTION
        WHEN NO_DATA_FOUND THEN RETURN FALSE;
        WHEN OTHERS THEN
            log_processing_step('EMPLOYEE_ACTIVITY_CHECK_ERROR', 'Error: ' || SQLERRM, p_employee_code);
            RETURN FALSE;
    END is_employee_active;

    FUNCTION has_previous_attendance_record(p_employee_code NUMBER) RETURN BOOLEAN IS
        v_dummy NUMBER;
    BEGIN
        SELECT 1 INTO v_dummy
        FROM   att_emp_attend_daily
        WHERE  emp_code = p_employee_code
        AND    work_date >= g_work_date - 30
        AND    work_date <  g_work_date
        AND    attend_status NOT IN ('ABSENT', 'MISSING')
        AND    ROWNUM = 1;

        RETURN TRUE;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN RETURN FALSE;
        WHEN OTHERS THEN RETURN FALSE;
    END has_previous_attendance_record;

    FUNCTION get_employee_department_name(p_employee_code NUMBER) RETURN VARCHAR2 IS
        v_department_name VARCHAR2(200);
    BEGIN
        SELECT ed.division_unit_name INTO v_department_name
        FROM   emp_division ed
        JOIN   emp_post ep ON ed.division_unit = ep.division_unit
        WHERE  ep.employee_no = p_employee_code
        AND    ROWNUM = 1;

        RETURN v_department_name;
    EXCEPTION
        WHEN OTHERS THEN RETURN 'UNKNOWN';
    END get_employee_department_name;

    -- ========================================================================
    -- LOAD ACTIVE EMPLOYEES
    -- ========================================================================
    PROCEDURE load_active_employees IS
        v_total_employees NUMBER := 0;
    BEGIN
        v_emp_codes.DELETE;
        v_emp_names.DELETE;
        v_emp_departments.DELETE;

        BEGIN
            SELECT e.employee_no, e.employee_name, NVL(ed.division_unit_name, 'UNKNOWN')
            BULK COLLECT INTO v_emp_codes, v_emp_names, v_emp_departments
            FROM   emp_master e
            LEFT JOIN emp_post ep ON e.employee_no = ep.employee_no
            LEFT JOIN emp_division ed ON ep.division_unit = ed.division_unit
            WHERE  e.employee_no IS NOT NULL
            AND    ep.employment_status = 1;
        EXCEPTION
            WHEN OTHERS THEN
                log_processing_step('LOAD_EMPLOYEES_SQL_ERROR', 'Error in SELECT: ' || SQLERRM);
                RETURN;
        END;

        -- ? Associative Array: DELETE بدل absence_table()
        v_absence_list.DELETE;

        IF v_emp_codes.COUNT > 0 THEN
            FOR i IN 1..v_emp_codes.COUNT LOOP
                v_absence_list(i).employee_code    := v_emp_codes(i);
                v_absence_list(i).employee_name    := v_emp_names(i);
                v_absence_list(i).attendance_date  := g_work_date;
                v_absence_list(i).absence_type     := 'ABSENT';
                v_absence_list(i).absence_reason   := 'No attendance record found';
                v_absence_list(i).source_system    := 'EMP_MASTER';
                v_absence_list(i).is_excused       := 'N';
                v_absence_list(i).department_name  := v_emp_departments(i);
                v_absence_list(i).additional_notes := '';
            END LOOP;

            v_total_employees := v_emp_codes.COUNT;
            log_processing_step('LOAD_EMPLOYEES_COMPLETE', 'Total employees loaded: ' || v_total_employees);
        ELSE
            log_processing_step('LOAD_EMPLOYEES_WARNING', 'No employees found in master tables');
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            log_processing_step('LOAD_EMPLOYEES_ERROR', 'Fatal error: ' || SQLERRM);
            RAISE;
    END load_active_employees;

    -- ========================================================================
    -- DETECT ABSENT EMPLOYEES
    -- ========================================================================
    PROCEDURE detect_absent_employees IS
        v_total_checked  NUMBER := 0;
        v_absent_count   NUMBER := 0;
        v_emp_code       NUMBER;
        v_emp_name       VARCHAR2(100);
        v_dept           VARCHAR2(200);

        TYPE emp_set_t IS TABLE OF BOOLEAN INDEX BY VARCHAR2(20);
        v_attendance_exists emp_set_t;
        v_staging_exists    emp_set_t;
        v_key               VARCHAR2(20);
    BEGIN
        IF v_absence_list.COUNT = 0 THEN
            log_processing_step('DETECTION_EMPTY', 'No employees loaded for absence detection');
            RETURN;
        END IF;

        v_total_checked := v_absence_list.COUNT;
        
        -- ? Associative Array: DELETE بدل absence_table()
        v_temp_absence_list.DELETE;

        -- 1. من emp_attend_daily
        FOR rec IN (
            SELECT DISTINCT emp_code
            FROM   att_emp_attend_daily
            WHERE  work_date >= g_work_date
            AND    work_date <  g_work_date + 1
            AND    attend_status NOT IN ('ABSENT', 'MISSING')
        ) LOOP
            v_key := TO_CHAR(rec.emp_code);
            v_attendance_exists(v_key) := TRUE;
        END LOOP;

        -- 2. من staging
        FOR rec IN (
            SELECT DISTINCT emp_code
            FROM   att_attendance_staging
            WHERE  work_date >= g_work_date
            AND    work_date <  g_work_date + 1
            AND    process_flag = 'P'
        ) LOOP
            v_key := TO_CHAR(rec.emp_code);
            v_staging_exists(v_key) := TRUE;
        END LOOP;

        -- 3. تحديد الغائبين
        FOR i IN 1..v_absence_list.COUNT LOOP
            IF v_absence_list(i).employee_code IS NOT NULL THEN
                v_emp_code := v_absence_list(i).employee_code;
                v_emp_name := v_absence_list(i).employee_name;
                v_dept     := v_absence_list(i).department_name;
                v_key      := TO_CHAR(v_emp_code);

                IF NOT (v_attendance_exists.EXISTS(v_key) OR v_staging_exists.EXISTS(v_key)) THEN
                    v_absent_count := v_absent_count + 1;

                    -- ? Associative Array: إسناد مباشر بدون EXTEND
                    v_temp_absence_list(v_absent_count).employee_code    := v_emp_code;
                    v_temp_absence_list(v_absent_count).employee_name    := NVL(v_emp_name, 'Unknown');
                    v_temp_absence_list(v_absent_count).attendance_date  := g_work_date;
                    v_temp_absence_list(v_absent_count).absence_type     := 'ABSENT';
                    v_temp_absence_list(v_absent_count).absence_reason   := 'No attendance record found';
                    v_temp_absence_list(v_absent_count).source_system    := 'AUTO_DETECTION';
                    v_temp_absence_list(v_absent_count).is_excused       := 'N';
                    v_temp_absence_list(v_absent_count).excuse_type      := NULL;
                    v_temp_absence_list(v_absent_count).department_name  := NVL(v_dept, 'Unknown');
                    v_temp_absence_list(v_absent_count).additional_notes := '';
                END IF;
            END IF;
        END LOOP;

        -- ? نقل v_temp_absence_list لـ v_absence_list
        v_absence_list.DELETE;
        FOR i IN 1..v_temp_absence_list.COUNT LOOP
            IF v_temp_absence_list.EXISTS(i) THEN
                v_absence_list(i) := v_temp_absence_list(i);
            END IF;
        END LOOP;
        
        v_temp_absence_list.DELETE;

        log_processing_step('ABSENCE_DETECTION_COMPLETE',
            'Employees checked: ' || v_total_checked || ' | Absent found: ' || v_absent_count);
    EXCEPTION
        WHEN OTHERS THEN
            log_processing_step('DETECTION_FATAL_ERROR', 'Fatal error: ' || SQLERRM);
            v_absence_list.DELETE;
            v_temp_absence_list.DELETE;
            RAISE;
    END detect_absent_employees;

    -- ========================================================================
    -- APPLY ALL EXCUSES
    -- ========================================================================
    PROCEDURE apply_all_excuses IS
        v_excuse_count NUMBER := 0;
        v_key          VARCHAR2(20);

        TYPE excuse_rec IS RECORD (emp_code NUMBER, excuse_type VARCHAR2(30));
        TYPE excuse_tab IS TABLE OF excuse_rec INDEX BY PLS_INTEGER;
        v_excuses excuse_tab;
        v_idx     PLS_INTEGER := 0;
    BEGIN
        IF v_absence_list.COUNT = 0 THEN
            log_processing_step('APPLY_EXCUSES_SKIP', 'No absences to process');
            RETURN;
        END IF;

        v_excuse_map.DELETE;
        log_processing_step('APPLY_EXCUSES_START',
            'Loading all excuses in one shot for ' || v_absence_list.COUNT || ' employees');

        FOR rec IN (
            SELECT employee_no AS emp_code, 'VACATION' AS excuse_type
            FROM   emp_vacation
            WHERE  g_work_date BETWEEN start_date AND NVL(end_date, start_date)
            UNION ALL
            SELECT employee_no, 'MISSION'
            FROM   emp_mission
            WHERE  g_work_date BETWEEN start_date AND NVL(end_date, start_date)
            UNION ALL
            SELECT employee_no, 'PERMISSION'
            FROM   emp_permission
            WHERE  permission_date = g_work_date
            UNION ALL
            SELECT employee_no, 'SICK_LEAVE'
            FROM   emp_vacation
            WHERE  g_work_date BETWEEN start_date AND NVL(end_date, start_date)
            AND    vac_type = 'SIC'
            UNION ALL
            SELECT employee_no, 'TRAINING'
            FROM   emp_training
            WHERE  g_work_date BETWEEN start_date AND NVL(end_date, start_date)
            UNION ALL
            SELECT employee_no, 'STOP_WORK'
            FROM   emp_stop_work
            WHERE  g_work_date BETWEEN start_date AND NVL(end_date, start_date)
            UNION ALL
            SELECT employee_no, 'INVT_ILL'
            FROM   emp_invt_ill
            WHERE  g_work_date BETWEEN absent_start_date AND NVL(absent_end_date, absent_start_date)
            UNION ALL
            SELECT employee_no, 'MILITARY'
            FROM   emp_mil_detail
            WHERE  g_work_date BETWEEN call_date AND NVL(call_period, call_date)
        ) LOOP
            v_idx := v_idx + 1;
            v_excuses(v_idx).emp_code    := rec.emp_code;
            v_excuses(v_idx).excuse_type := rec.excuse_type;
        END LOOP;

        log_processing_step('APPLY_EXCUSES_LOADED',
            'Loaded ' || v_idx || ' excuse records from all tables');

        FOR i IN 1..v_idx LOOP
            v_key := TO_CHAR(v_excuses(i).emp_code);
            IF NOT v_excuse_map.EXISTS(v_key) THEN
                v_excuse_map(v_key) := v_excuses(i).excuse_type;
            END IF;
        END LOOP;

        FOR i IN 1..v_absence_list.COUNT LOOP
            IF v_absence_list(i).is_excused = 'Y' THEN
                CONTINUE;
            END IF;

            v_key := TO_CHAR(v_absence_list(i).employee_code);

            IF v_excuse_map.EXISTS(v_key) THEN
                v_absence_list(i).absence_type := v_excuse_map(v_key);
                v_absence_list(i).is_excused   := 'Y';
                v_absence_list(i).excuse_type  := v_excuse_map(v_key);
                v_excuse_count := v_excuse_count + 1;
            END IF;
        END LOOP;

        log_processing_step('APPLY_EXCUSES_COMPLETE',
            'Total excuses applied: ' || v_excuse_count ||
            ' | Remaining absences: ' || (v_absence_list.COUNT - v_excuse_count));
    EXCEPTION
        WHEN OTHERS THEN
            log_processing_step('APPLY_EXCUSES_FATAL',
                'Fatal error: ' || SQLERRM || ' | Backtrace: ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
            RAISE;
    END apply_all_excuses;

    -- ========================================================================
    -- إجراءات فردية (للتوافق)
    -- ========================================================================
    PROCEDURE apply_vacation_excuse        IS BEGIN NULL; END;
    PROCEDURE apply_mission_excuse         IS BEGIN NULL; END;
    PROCEDURE apply_permission_excuse      IS BEGIN NULL; END;
    PROCEDURE apply_infect_work_excuse     IS BEGIN NULL; END;
    PROCEDURE apply_training_excuse        IS BEGIN NULL; END;
    PROCEDURE apply_invt_ill_excuse        IS BEGIN NULL; END;
    PROCEDURE apply_military_excuse        IS BEGIN NULL; END;
    PROCEDURE apply_emergency_leave_excuse IS BEGIN NULL; END;

    -- ========================================================================
    -- EXCLUDE NIGHT SHIFT EMPLOYEES
    -- ========================================================================
    PROCEDURE exclude_night_shift_employees IS
        v_excluded_count NUMBER := 0;
        v_key            VARCHAR2(20);

        TYPE emp_set_t IS TABLE OF BOOLEAN INDEX BY VARCHAR2(20);
        v_night_set emp_set_t;
    BEGIN
        IF v_absence_list.COUNT = 0 THEN RETURN; END IF;

        FOR rec IN (
            SELECT emp_code
            FROM   att_emp_attend_daily
            WHERE  work_date >= g_work_date
            AND    work_date <  g_work_date + 1
            AND    NVL(is_night, 'N') = 'Y'
        ) LOOP
            v_key := TO_CHAR(rec.emp_code);
            v_night_set(v_key) := TRUE;
        END LOOP;

        FOR i IN 1..v_absence_list.COUNT LOOP
            v_key := TO_CHAR(v_absence_list(i).employee_code);

            IF v_night_set.EXISTS(v_key) THEN
                v_absence_list(i).absence_type     := 'NIGHT_SHIFT';
                v_absence_list(i).absence_reason   := 'Night shift employee';
                v_absence_list(i).source_system    := 'SHIFT_EXCLUSION';
                v_absence_list(i).is_excused       := 'Y';
                v_absence_list(i).additional_notes := 'Adjusted for night shift';
                v_excluded_count := v_excluded_count + 1;
            END IF;
        END LOOP;

        log_processing_step('NIGHT_SHIFT_EXCLUSION_COMPLETE',
            'Night shift employees excluded: ' || v_excluded_count);
    END exclude_night_shift_employees;

    -- ========================================================================
    -- HANDLE HALF DAY ATTENDANCE
    -- ========================================================================
    PROCEDURE handle_half_day_attendance IS
        v_adjusted_count NUMBER := 0;
        v_key            VARCHAR2(20);

        TYPE att_rec IS RECORD (
            emp_code     NUMBER,
            status       VARCHAR2(20),
            first_in     DATE,
            work_min     NUMBER,
            late_min     NUMBER
        );
        TYPE att_tab IS TABLE OF att_rec INDEX BY PLS_INTEGER;
        v_att att_tab;
        v_idx PLS_INTEGER := 0;
    BEGIN
        IF v_absence_list.COUNT = 0 THEN RETURN; END IF;

        FOR rec IN (
            SELECT emp_code, attend_status, first_in,
                   NVL(work_min, 0) AS work_min,
                   NVL(late_min, 0) AS late_min
            FROM   att_emp_attend_daily
            WHERE  work_date >= g_work_date
            AND    work_date <  g_work_date + 1
        ) LOOP
            v_idx := v_idx + 1;
            v_att(v_idx).emp_code := rec.emp_code;
            v_att(v_idx).status   := rec.attend_status;
            v_att(v_idx).first_in := rec.first_in;
            v_att(v_idx).work_min := rec.work_min;
            v_att(v_idx).late_min := rec.late_min;
        END LOOP;

        FOR i IN 1..v_absence_list.COUNT LOOP
            IF v_absence_list(i).is_excused = 'Y' THEN
                CONTINUE;
            END IF;

            FOR j IN 1..v_idx LOOP
                IF v_att(j).emp_code = v_absence_list(i).employee_code THEN
                    IF v_att(j).late_min >= 240 THEN
                        v_absence_list(i).absence_type     := 'HALF_DAY';
                        v_absence_list(i).absence_reason   := 'Late arrival >= 4 hours';
                        v_absence_list(i).additional_notes := 'Half Day: Late arrival';
                        v_adjusted_count := v_adjusted_count + 1;
                    ELSIF v_att(j).work_min < 240 THEN
                        v_absence_list(i).absence_type     := 'HALF_DAY';
                        v_absence_list(i).absence_reason   := 'Worked less than 4 hours';
                        v_absence_list(i).additional_notes := 'Half Day: Insufficient hours';
                        v_adjusted_count := v_adjusted_count + 1;
                    ELSIF v_att(j).status = 'HALF_DAY' THEN
                        v_absence_list(i).absence_type     := 'HALF_DAY';
                        v_absence_list(i).absence_reason   := 'Marked as half day';
                        v_absence_list(i).additional_notes := 'Half Day: System marked';
                        v_adjusted_count := v_adjusted_count + 1;
                    END IF;
                    EXIT;
                END IF;
            END LOOP;
        END LOOP;

        IF v_adjusted_count > 0 THEN
            log_processing_step('HALF_DAY_PROCESSING_COMPLETE',
                'Half day adjustments made: ' || v_adjusted_count);
        END IF;
    END handle_half_day_attendance;

    -- ========================================================================
    -- BULK INSERT ABSENCE RECORDS
    -- ========================================================================
    PROCEDURE bulk_insert_absence_records(p_absence_list IN absence_table) IS
        TYPE emp_absent_rec IS RECORD (
            employee_no    NUMBER,
            abs_type       VARCHAR2(3),
            effective_side VARCHAR2(1),
            start_date     DATE,
            end_date       DATE,
            period         NUMBER,
            inuser         NUMBER,
            indate         DATE,
            moduser        NUMBER,
            moddate        DATE,
            audit_flag     NUMBER
        );
        TYPE emp_absent_tab IS TABLE OF emp_absent_rec INDEX BY PLS_INTEGER;
        v_absent_tab emp_absent_tab;

        v_counter         NUMBER := 0;
        v_inserted_count  NUMBER := 0;
        v_duplicate_count NUMBER := 0;
        v_skipped_count   NUMBER := 0;

        TYPE dup_set_t IS TABLE OF BOOLEAN INDEX BY VARCHAR2(50);
        v_dup_set dup_set_t;
        v_key     VARCHAR2(50);
    BEGIN
        IF p_absence_list.COUNT = 0 THEN
            log_processing_step('BULK_INSERT_SKIP', 'No records to insert');
            RETURN;
        END IF;

        log_processing_step('BULK_INSERT_START',
            'Starting bulk insert for ' || p_absence_list.COUNT || ' records');

        FOR rec IN (
            SELECT employee_no, start_date
            FROM   att_emp_absent_daily
            WHERE  start_date >= g_work_date
            AND    start_date <  g_work_date + 1
        ) LOOP
            v_key := TO_CHAR(rec.employee_no) || '_' ||
                     TO_CHAR(TRUNC(rec.start_date), 'YYYYMMDD');
            v_dup_set(v_key) := TRUE;
        END LOOP;

        FOR i IN 1..p_absence_list.COUNT LOOP
            IF p_absence_list(i).employee_code IS NULL THEN
                v_skipped_count := v_skipped_count + 1;
                CONTINUE;
            END IF;

            v_key := TO_CHAR(p_absence_list(i).employee_code) || '_' ||
                     TO_CHAR(TRUNC(p_absence_list(i).attendance_date), 'YYYYMMDD');

            IF v_dup_set.EXISTS(v_key) THEN
                v_duplicate_count := v_duplicate_count + 1;
                CONTINUE;
            END IF;

            v_dup_set(v_key) := TRUE;

            v_counter := v_counter + 1;
            v_absent_tab(v_counter).employee_no    := p_absence_list(i).employee_code;
            v_absent_tab(v_counter).abs_type       := SUBSTR(p_absence_list(i).absence_type, 1, 3);
            v_absent_tab(v_counter).effective_side := '1';
            v_absent_tab(v_counter).start_date     := p_absence_list(i).attendance_date;
            v_absent_tab(v_counter).end_date       := p_absence_list(i).attendance_date;
            v_absent_tab(v_counter).period         := 1;
            v_absent_tab(v_counter).inuser         := 0;
            v_absent_tab(v_counter).indate         := SYSDATE;
            v_absent_tab(v_counter).moduser        := 0;
            v_absent_tab(v_counter).moddate        := SYSDATE;
            v_absent_tab(v_counter).audit_flag     := 0;
        END LOOP;

        IF v_counter > 0 THEN
            FORALL i IN 1..v_counter
                INSERT INTO att_emp_absent_daily (
                    employee_no, abs_type, effective_side,
                    start_date, end_date, period,
                    inuser, indate, moduser, moddate, audit_flag
                ) VALUES (
                    v_absent_tab(i).employee_no, v_absent_tab(i).abs_type,
                    v_absent_tab(i).effective_side,
                    v_absent_tab(i).start_date, v_absent_tab(i).end_date,
                    v_absent_tab(i).period,
                    v_absent_tab(i).inuser, v_absent_tab(i).indate,
                    v_absent_tab(i).moduser, v_absent_tab(i).moddate,
                    v_absent_tab(i).audit_flag
                );

            v_inserted_count := SQL%ROWCOUNT;
        END IF;

        log_processing_step('BULK_INSERT_COMPLETE',
            'Inserted: ' || v_inserted_count ||
            ' | Duplicates: ' || v_duplicate_count ||
            ' | Invalid: ' || v_skipped_count);
    EXCEPTION
        WHEN OTHERS THEN
            log_processing_step('BULK_INSERT_ERROR', 'Error: ' || SQLERRM);
            RAISE;
    END bulk_insert_absence_records;

    -- ========================================================================
    -- INSERT ABSENCE RECORDS
    -- ========================================================================
    PROCEDURE insert_absence_records IS
    BEGIN
        IF v_absence_list.COUNT = 0 THEN
            log_processing_step('INSERT_SKIPPED', 'No absence records to insert');
            RETURN;
        END IF;

        bulk_insert_absence_records(v_absence_list);
    END insert_absence_records;

    -- ========================================================================
    -- BULK INSERT ABS
    -- ========================================================================
    PROCEDURE bulk_insert_abs IS
        TYPE abs_rec IS RECORD (emp_code NUMBER, work_date DATE, abs_type VARCHAR2(3));
        TYPE abs_tab IS TABLE OF abs_rec INDEX BY PLS_INTEGER;
        v_abs_tab abs_tab;
        v_counter NUMBER := 0;
        v_inserted_count NUMBER := 0;
    BEGIN
        log_processing_step('BULK_ABS_START',
            'Starting bulk insert for date: ' || TO_CHAR(g_work_date, 'DD-MM-YYYY'));

        FOR rec IN (
            SELECT d.EMPLOYEE_NO AS emp_code,
                   d.START_DATE  AS work_date,
                   d.ABS_TYPE    AS abs_type
            FROM   att_emp_absent_daily d
            WHERE  d.START_DATE >= g_work_date
            AND    d.START_DATE <  g_work_date + 1
            AND    NOT EXISTS (
                SELECT 1 FROM emp_absent a
                WHERE  a.employee_no = d.EMPLOYEE_NO
                AND    a.start_date >= g_work_date
                AND    a.start_date <  g_work_date + 1
                AND    a.abs_type = d.ABS_TYPE
            )
        ) LOOP
            v_counter := v_counter + 1;
            v_abs_tab(v_counter).emp_code  := rec.emp_code;
            v_abs_tab(v_counter).work_date := rec.work_date;
            v_abs_tab(v_counter).abs_type  := rec.abs_type;
        END LOOP;

        IF v_counter = 0 THEN
            log_processing_step('BULK_ABS_SKIP',
                'No new records to insert for date: ' || TO_CHAR(g_work_date, 'DD-MM-YYYY'));
            RETURN;
        END IF;

        log_processing_step('BULK_ABS_COUNT',
            'Found ' || v_counter || ' new records to insert');

        BEGIN
            FORALL i IN 1..v_counter
                INSERT INTO emp_absent (
                    employee_no, abs_type, effective_side,
                    start_date, end_date, period,
                    inuser, indate, moduser, moddate, audit_flag
                ) VALUES (
                    v_abs_tab(i).emp_code,
                    v_abs_tab(i).abs_type,
                    '1',
                    v_abs_tab(i).work_date,
                    v_abs_tab(i).work_date,
                    1, 0, SYSDATE, 0, SYSDATE, 0
                );

            v_inserted_count := SQL%ROWCOUNT;

            log_processing_step('BULK_ABS_COMPLETE',
                'Inserted ' || v_inserted_count || ' records into emp_absent');
            COMMIT;
        EXCEPTION
            WHEN OTHERS THEN
                log_processing_step('BULK_ABS_ERROR', 'Error: ' || SQLERRM);
                RAISE;
        END;
    END bulk_insert_abs;

    -- ========================================================================
    -- MANUAL ABSENCE RECORD
    -- ========================================================================
    PROCEDURE apply_manual_absence_record(
        p_employee_code  NUMBER,
        p_absence_type   VARCHAR2,
        p_absence_reason VARCHAR2
    ) IS
        v_manual_record absence_record;
    BEGIN
        IF g_work_date IS NULL THEN
            RAISE_APPLICATION_ERROR(-20003, 'g_work_date is not set');
        END IF;

        IF NOT is_employee_active(p_employee_code) THEN
            RAISE_APPLICATION_ERROR(-20002,
                'Employee not found or inactive: ' || p_employee_code);
        END IF;

        v_manual_record.employee_code    := p_employee_code;
        v_manual_record.employee_name    := NULL;
        v_manual_record.attendance_date  := g_work_date;
        v_manual_record.absence_type     := UPPER(p_absence_type);
        v_manual_record.absence_reason   := SUBSTR(p_absence_reason, 1, 200);
        v_manual_record.source_system    := 'MANUAL_ENTRY';
        v_manual_record.is_excused       := 'Y';
        v_manual_record.excuse_type      := UPPER(p_absence_type);
        v_manual_record.department_name  := get_employee_department_name(p_employee_code);
        v_manual_record.additional_notes := 'Manually applied by user';

        -- ? Associative Array: إسناد مباشر
        v_absence_list(v_absence_list.COUNT + 1) := v_manual_record;

        BEGIN
            INSERT INTO att_emp_absent_daily (
                EMPLOYEE_NO, ABS_TYPE, EFFECTIVE_SIDE,
                START_DATE, END_DATE, PERIOD,
                INUSER, INDATE, MODUSER, MODDATE, AUDIT_FLAG
            ) VALUES (
                p_employee_code, SUBSTR(UPPER(p_absence_type), 1, 3), '1',
                g_work_date, g_work_date, 1,
                0, SYSDATE, 0, SYSDATE, 1
            );

            log_processing_step('MANUAL_ABSENCE_RECORDED',
                'Manual absence for employee: ' || p_employee_code ||
                ' | Type: ' || p_absence_type, p_employee_code);
        EXCEPTION
            WHEN OTHERS THEN
                log_processing_step('MANUAL_ABSENCE_ERROR', 'Error: ' || SQLERRM, p_employee_code);
                RAISE;
        END;
    END apply_manual_absence_record;

    -- ========================================================================
    -- GENERATE DAILY ABSENCE REPORT
    -- ========================================================================
    PROCEDURE generate_daily_absence_report(p_report_date DATE) IS
        v_start_time      DATE := SYSDATE;
        v_step_start      DATE;
        v_step_duration   NUMBER;
        v_total_duration  NUMBER;
        v_completed_steps NUMBER := 0;
    BEGIN
        g_work_date := TRUNC(p_report_date);

        IF is_weekend(g_work_date) THEN
            log_processing_step('WEEKEND_SKIP',
                'Skipped weekend: ' || TO_CHAR(g_work_date, 'DD-MM-YYYY'));
            RETURN;
        END IF;

        IF is_official_holiday(g_work_date) THEN
            log_processing_step('OFFICIAL_HOLIDAY_SKIP',
                'Skipped holiday: ' || TO_CHAR(g_work_date, 'DD-MM-YYYY'));
            RETURN;
        END IF;

        log_processing_step('REPORT_GENERATION_START',
            'Starting daily absence report for: ' || TO_CHAR(g_work_date, 'DD-MM-YYYY'));

        v_step_start := SYSDATE;
        load_active_employees;
        v_step_duration := ROUND((SYSDATE - v_step_start) * 86400, 2);
        log_processing_step('STEP_TIMING', 'Load employees: ' || v_step_duration || ' seconds');
        v_completed_steps := v_completed_steps + 1;

        v_step_start := SYSDATE;
        detect_absent_employees;
        v_step_duration := ROUND((SYSDATE - v_step_start) * 86400, 2);
        log_processing_step('STEP_TIMING', 'Detect absent: ' || v_step_duration || ' seconds');
        v_completed_steps := v_completed_steps + 1;

        IF v_absence_list.COUNT = 0 THEN
            log_processing_step('NO_ABSENCES_DETECTED', 'No absences detected');
            COMMIT;
            RETURN;
        END IF;

        v_step_start := SYSDATE;
        exclude_night_shift_employees;
        v_step_duration := ROUND((SYSDATE - v_step_start) * 86400, 2);
        log_processing_step('STEP_TIMING', 'Exclude night shift: ' || v_step_duration || ' seconds');
        v_completed_steps := v_completed_steps + 1;

        v_step_start := SYSDATE;
        apply_all_excuses;
        v_step_duration := ROUND((SYSDATE - v_step_start) * 86400, 2);
        log_processing_step('STEP_TIMING', 'Apply all excuses (unified): ' || v_step_duration || ' seconds');
        v_completed_steps := v_completed_steps + 1;

        v_step_start := SYSDATE;
        handle_half_day_attendance;
        v_step_duration := ROUND((SYSDATE - v_step_start) * 86400, 2);
        log_processing_step('STEP_TIMING', 'Handle half day: ' || v_step_duration || ' seconds');
        v_completed_steps := v_completed_steps + 1;

        v_step_start := SYSDATE;
        insert_absence_records;
        v_step_duration := ROUND((SYSDATE - v_step_start) * 86400, 2);
        log_processing_step('STEP_TIMING', 'Insert absence records: ' || v_step_duration || ' seconds');
        v_completed_steps := v_completed_steps + 1;

        v_step_start := SYSDATE;
        bulk_insert_abs;
        v_step_duration := ROUND((SYSDATE - v_step_start) * 86400, 2);
        log_processing_step('STEP_TIMING', 'Insert ABS records: ' || v_step_duration || ' seconds');
        v_completed_steps := v_completed_steps + 1;

        COMMIT;
        log_processing_step('FINAL_COMMIT', 'Transaction committed');

        v_total_duration := ROUND((SYSDATE - v_start_time) * 86400, 2);

        DECLARE
            v_total_absence_count     NUMBER := v_absence_list.COUNT;
            v_excused_absence_count   NUMBER := 0;
            v_unexcused_absence_count NUMBER := 0;
            v_half_day_count          NUMBER := 0;
        BEGIN
            FOR i IN 1..v_absence_list.COUNT LOOP
                CASE
                    WHEN v_absence_list(i).is_excused = 'Y' THEN
                        v_excused_absence_count := v_excused_absence_count + 1;
                    WHEN v_absence_list(i).absence_type = 'HALF_DAY' THEN
                        v_half_day_count := v_half_day_count + 1;
                    ELSE
                        v_unexcused_absence_count := v_unexcused_absence_count + 1;
                END CASE;
            END LOOP;

            log_processing_step('REPORT_GENERATION_COMPLETE',
                'Daily absence report generated!' || CHR(10) ||
                'Total Time: ' || v_total_duration || ' seconds' || CHR(10) ||
                'Steps: ' || v_completed_steps || CHR(10) ||
                'Total Absences: ' || v_total_absence_count || CHR(10) ||
                '  - Excused: ' || v_excused_absence_count || CHR(10) ||
                '  - Unexcused: ' || v_unexcused_absence_count || CHR(10) ||
                '  - Half Day: ' || v_half_day_count);
        END;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            log_processing_step('REPORT_GENERATION_FAILED',
                'Failed: ' || SQLERRM || ' | Backtrace: ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
            RAISE;
    END generate_daily_absence_report;

    -- ========================================================================
    -- GENERATE ABSENCE REPORT RANGE
    -- ========================================================================
    PROCEDURE generate_absence_report_range(
        p_start_date DATE,
        p_end_date   DATE
    ) IS
        v_current_date   DATE;
        v_day_count      NUMBER := 0;
        v_abs_count      NUMBER := 0;
        v_total_absences NUMBER := 0;
        v_error_count    NUMBER := 0;
        v_success_days   NUMBER := 0;
        v_start_time     TIMESTAMP := SYSTIMESTAMP;

        v_holiday_set holiday_set_tab;
        v_key         VARCHAR2(8);
    BEGIN
        IF TRUNC(p_start_date) > TRUNC(p_end_date) THEN
            log_processing_step('PERIOD_ERROR', 'Start date cannot be greater than end date');
            RETURN;
        END IF;

        log_processing_step('PERIOD_START',
            'Processing from ' || TO_CHAR(p_start_date, 'DD-MM-YYYY') ||
            ' to ' || TO_CHAR(p_end_date, 'DD-MM-YYYY'));

        v_holiday_set := load_holiday_set(p_start_date, p_end_date);
        log_processing_step('PERIOD_HOLIDAYS_LOADED',
            'Official holidays preloaded: ' || v_holiday_set.COUNT || ' days');

        v_current_date := TRUNC(p_start_date);

        WHILE v_current_date <= TRUNC(p_end_date) LOOP

            v_key := TO_CHAR(v_current_date, 'YYYYMMDD');

            IF is_weekend(v_current_date) THEN
                log_processing_step('WEEKEND_SKIP',
                    'Skipped weekend: ' || TO_CHAR(v_current_date, 'DD-MM-YYYY'));
                v_day_count := v_day_count + 1;
                v_current_date := v_current_date + 1;
                CONTINUE;
            END IF;

            IF v_holiday_set.EXISTS(v_key) THEN
                log_processing_step('OFFICIAL_HOLIDAY_SKIP',
                    'Skipped holiday: ' || TO_CHAR(v_current_date, 'DD-MM-YYYY'));
                v_day_count := v_day_count + 1;
                v_current_date := v_current_date + 1;
                CONTINUE;
            END IF;

            BEGIN
                v_absence_list.DELETE;
                v_abs_count := 0;
                g_work_date := v_current_date;

                load_active_employees;
                detect_absent_employees;

                IF v_absence_list.COUNT > 0 THEN
                    exclude_night_shift_employees;
                    apply_all_excuses;
                    handle_half_day_attendance;
                    insert_absence_records;
                    bulk_insert_abs;

                    v_abs_count := v_absence_list.COUNT;
                    v_total_absences := v_total_absences + v_abs_count;
                    v_success_days := v_success_days + 1;
                END IF;

                log_processing_step('PERIOD_DAY_COMPLETE',
                    'Date: ' || TO_CHAR(v_current_date, 'DD-MM-YYYY') ||
                    ' | Absences: ' || v_abs_count);

                COMMIT;
            EXCEPTION
                WHEN OTHERS THEN
                    v_error_count := v_error_count + 1;
                    log_processing_step('PERIOD_DAY_ERROR',
                        'Error on ' || TO_CHAR(v_current_date, 'DD-MM-YYYY') ||
                        ' : ' || SQLERRM);
                    ROLLBACK;
            END;

            v_day_count := v_day_count + 1;
            v_current_date := v_current_date + 1;
        END LOOP;

        COMMIT;

        log_processing_step('PERIOD_COMPLETE',
            'Period Completed Successfully' || CHR(10) ||
            '----------------------------------' || CHR(10) ||
            'Total Days Processed: ' || v_day_count || CHR(10) ||
            'Days With Absences: ' || v_success_days || CHR(10) ||
            'Total Absence Records: ' || v_total_absences || CHR(10) ||
            'Errors: ' || v_error_count || CHR(10) ||
            'Processing Time (min): ' ||
            ROUND((SYSDATE - CAST(v_start_time AS DATE)) * 1440, 2));
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            log_processing_step('PERIOD_FATAL_ERROR', 'Fatal error: ' || SQLERRM);
            RAISE;
    END generate_absence_report_range;

    -- ========================================================================
    -- LOAD ABSENCES TO TEMP
    -- ========================================================================
    PROCEDURE load_absences_to_temp(
        p_from_date DATE,
        p_to_date   DATE
    ) IS
        v_date DATE;
        v_absence_collection absence_table;

        TYPE temp_absence_rec IS RECORD (
            TEMP_ID        NUMBER,
            EMPLOYEE_NO    NUMBER,
            ABS_TYPE       VARCHAR2(3),
            EFFECTIVE_SIDE VARCHAR2(1),
            START_DATE     DATE,
            END_DATE       DATE,
            PERIOD         NUMBER,
            INUSER         NUMBER,
            INDATE         DATE,
            MODUSER        NUMBER,
            MODDATE        DATE,
            AUDIT_FLAG     NUMBER,
            EXCUSED_FLAG   CHAR(1),
            SOURCE_DATE    DATE
        );
        TYPE temp_absence_tab IS TABLE OF temp_absence_rec INDEX BY PLS_INTEGER;
        v_temp_list temp_absence_tab;

        v_index          NUMBER;
        v_total_absences NUMBER := 0;
        v_seq_value      NUMBER;
        v_key            VARCHAR2(8);

        v_holiday_set holiday_set_tab;

        FUNCTION get_next_seq RETURN NUMBER IS
            v_next NUMBER;
        BEGIN
            SELECT att_absence_temp_seq.NEXTVAL INTO v_next FROM DUAL;
            RETURN v_next;
        END get_next_seq;
    BEGIN
        DELETE FROM att_absence_temp;

        v_date := TRUNC(p_from_date);

        log_processing_step('LOAD_TEMP_START',
            'Loading from ' || TO_CHAR(p_from_date, 'DD-MM-YYYY') ||
            ' to ' || TO_CHAR(p_to_date, 'DD-MM-YYYY'));

        v_holiday_set := load_holiday_set(p_from_date, p_to_date);

        WHILE v_date <= TRUNC(p_to_date) LOOP

            v_key := TO_CHAR(v_date, 'YYYYMMDD');

            IF is_weekend(v_date) THEN
                log_processing_step('WEEKEND_SKIP',
                    'Skipped weekend: ' || TO_CHAR(v_date, 'DD-MM-YYYY'));
                v_date := v_date + 1;
                CONTINUE;
            END IF;

            IF v_holiday_set.EXISTS(v_key) THEN
                log_processing_step('OFFICIAL_HOLIDAY_SKIP',
                    'Skipped holiday: ' || TO_CHAR(v_date, 'DD-MM-YYYY'));
                v_date := v_date + 1;
                CONTINUE;
            END IF;

            g_work_date := v_date;

            load_active_employees;
            detect_absent_employees;
            exclude_night_shift_employees;
            apply_all_excuses;
            handle_half_day_attendance;

            -- ? نقل v_absence_list لـ v_absence_collection
            v_absence_collection.DELETE;
            FOR i IN 1..v_absence_list.COUNT LOOP
                IF v_absence_list.EXISTS(i) THEN
                    v_absence_collection(i) := v_absence_list(i);
                END IF;
            END LOOP;

            v_index := 0;
            FOR i IN 1..v_absence_collection.COUNT LOOP
                IF v_absence_collection.EXISTS(i) THEN
                    v_index := v_index + 1;
                    v_seq_value := get_next_seq;

                    IF v_absence_collection(i).is_excused = 'Y' THEN
                        v_temp_list(v_index).ABS_TYPE :=
                            SUBSTR(NVL(v_absence_collection(i).excuse_type,
                                        v_absence_collection(i).absence_type), 1, 3);
                    ELSE
                        v_temp_list(v_index).ABS_TYPE := 'ABS';
                    END IF;

                    v_temp_list(v_index).TEMP_ID        := v_seq_value;
                    v_temp_list(v_index).EMPLOYEE_NO    := v_absence_collection(i).employee_code;
                    v_temp_list(v_index).EFFECTIVE_SIDE := '1';
                    v_temp_list(v_index).START_DATE     := v_absence_collection(i).attendance_date;
                    v_temp_list(v_index).END_DATE       := v_absence_collection(i).attendance_date;
                    v_temp_list(v_index).PERIOD         := 1;
                    v_temp_list(v_index).INUSER         := 0;
                    v_temp_list(v_index).INDATE         := SYSDATE;
                    v_temp_list(v_index).MODUSER        := 0;
                    v_temp_list(v_index).MODDATE        := SYSDATE;
                    v_temp_list(v_index).AUDIT_FLAG     := 0;
                    v_temp_list(v_index).EXCUSED_FLAG   := v_absence_collection(i).is_excused;
                    v_temp_list(v_index).SOURCE_DATE    := v_date;
                END IF;
            END LOOP;

            IF v_index > 0 THEN
                FORALL j IN 1 .. v_index
                    INSERT INTO att_absence_temp (
                        TEMP_ID, EMPLOYEE_NO, ABS_TYPE, EFFECTIVE_SIDE,
                        START_DATE, END_DATE, PERIOD,
                        INUSER, INDATE, MODUSER, MODDATE,
                        AUDIT_FLAG, EXCUSED_FLAG, SOURCE_DATE
                    ) VALUES (
                        v_temp_list(j).TEMP_ID,
                        v_temp_list(j).EMPLOYEE_NO,
                        v_temp_list(j).ABS_TYPE,
                        v_temp_list(j).EFFECTIVE_SIDE,
                        v_temp_list(j).START_DATE,
                        v_temp_list(j).END_DATE,
                        v_temp_list(j).PERIOD,
                        v_temp_list(j).INUSER,
                        v_temp_list(j).INDATE,
                        v_temp_list(j).MODUSER,
                        v_temp_list(j).MODDATE,
                        v_temp_list(j).AUDIT_FLAG,
                        v_temp_list(j).EXCUSED_FLAG,
                        v_temp_list(j).SOURCE_DATE
                    );

                v_total_absences := v_total_absences + v_index;

                log_processing_step('LOAD_TEMP_DAY',
                    'Date: ' || TO_CHAR(v_date, 'DD-MM-YYYY') ||
                    ' | Absences: ' || v_index);
            END IF;

            COMMIT;
            v_date := v_date + 1;
        END LOOP;

        COMMIT;

        log_processing_step('LOAD_TEMP_COMPLETE',
            'Total days: ' || (TRUNC(p_to_date) - TRUNC(p_from_date) + 1) ||
            ' | Total absences: ' || v_total_absences);
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            log_processing_step('LOAD_TEMP_ERROR',
                SQLERRM || ' | Date: ' || TO_CHAR(v_date, 'DD-MM-YYYY'));
            RAISE;
    END load_absences_to_temp;

END employee_absence_manager;
/
