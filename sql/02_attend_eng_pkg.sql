create or replace PACKAGE attend_eng_pkg IS
    g_work_date  DATE;
    g_step_name  VARCHAR2(400);
    v_debug_mode BOOLEAN := FALSE;

    TYPE attend_rec IS RECORD(
        emp_code            attendance_staging.emp_code%TYPE,
        first_name          attendance_staging.first_name%TYPE,
        last_name           attendance_staging.last_name%TYPE,
        punch_time          attendance_staging.punch_time%TYPE,
        weekday             attendance_staging.weekday%TYPE,
        work_date           attendance_staging.work_date%TYPE,
        punch_status        attendance_staging.punch_status%TYPE,
        file_name           attendance_staging.file_name%TYPE,
        process_flag        attendance_staging.process_flag%TYPE,
        session_id          attendance_staging.session_id%TYPE
    );

    TYPE attend_tab IS TABLE OF attend_rec INDEX BY PLS_INTEGER;
    v_tab attend_tab;

    TYPE shift_rec IS RECORD (
        emp_code        attendance_staging.emp_code%TYPE,
        work_date       attendance_staging.work_date%TYPE,
        shift_id        att_emp_shift.shift_id%TYPE,
        shift_type      VARCHAR2(10),
        start_time      NUMBER,
        end_time        NUMBER,
        is_night        CHAR(1),
        first_in        DATE,
        last_out        DATE,
        punch_count     NUMBER,
        in_count        NUMBER,
        out_count       NUMBER,
        mid_count       NUMBER,
        session_id      NUMBER
    );
    TYPE shift_tab IS TABLE OF shift_rec INDEX BY PLS_INTEGER;
    v_shift shift_tab;

    TYPE date_array IS TABLE OF DATE INDEX BY PLS_INTEGER;

    TYPE mid_rec IS RECORD (
        emp_code    NUMBER,
        punch_time  DATE,
        work_date   DATE,
        session_id  NUMBER,
        shift_type  VARCHAR2(50)
    );

    TYPE mid_tab IS TABLE OF mid_rec INDEX BY PLS_INTEGER;
    v_mid_collection mid_tab;

    -- ==================== BASIC FUNCTIONS ====================
    FUNCTION calculate_overtime(
        p_first_in    IN DATE,
        p_last_out    IN DATE,
        p_shift_start IN DATE,
        p_shift_end   IN DATE,
        p_is_night    IN CHAR DEFAULT 'N',
        p_shift_id    IN NUMBER DEFAULT NULL
    ) RETURN NUMBER;

    FUNCTION calculate_late_minutes(
        p_shift_start IN DATE,
        p_first_in    IN DATE,
        p_shift_id    IN NUMBER DEFAULT NULL
    ) RETURN NUMBER;

    FUNCTION calculate_early_out(
        p_shift_end   IN DATE,
        p_last_out    IN DATE,
        p_shift_id    IN NUMBER DEFAULT NULL,
        p_is_night    IN CHAR DEFAULT 'N'
    ) RETURN NUMBER;

    FUNCTION determine_attend_status(
        p_work_min    IN NUMBER,
        p_late_min    IN NUMBER,
        p_first_in    IN DATE,
        p_last_out    IN DATE,
        p_emp_code    IN NUMBER DEFAULT NULL
    ) RETURN VARCHAR2;

    FUNCTION calc_work_min(
        p_shift_start IN DATE,
        p_shift_end   IN DATE,
        p_first_in    IN DATE,
        p_last_out    IN DATE
    ) RETURN NUMBER;

    FUNCTION calc_work_min_hours(
        p_shift_start_hour IN NUMBER,
        p_shift_end_hour   IN NUMBER,
        p_first_in         IN DATE,
        p_last_out         IN DATE,
        p_work_date        IN DATE,
        p_is_night         IN CHAR DEFAULT 'N'
    ) RETURN NUMBER;

    FUNCTION early_in_min (
        p_shift_start IN DATE,
        p_first_in    IN DATE,
        p_shift_id    IN NUMBER
    ) RETURN NUMBER;

    FUNCTION early_in_hours (
        p_shift_start IN DATE,
        p_first_in    IN DATE,
        p_shift_id    IN NUMBER DEFAULT NULL
    ) RETURN NUMBER;

    FUNCTION calculate_night_shift_hours(
        p_first_in      IN DATE,
        p_last_out      IN DATE,
        p_shift_start   IN DATE,
        p_shift_end     IN DATE,
        p_night_start   IN NUMBER DEFAULT NULL,
        p_night_end     IN NUMBER DEFAULT NULL
    ) RETURN NUMBER;

    -- ==================== MAIN PROCEDURES ====================
    PROCEDURE run_daily_attendance(p_work_date DATE);
    PROCEDURE log_engine_step(
        p_step VARCHAR2,
        p_msg VARCHAR2,
        p_work_date DATE,
        p_emp_code NUMBER DEFAULT NULL
    );
    PROCEDURE lock_day(p_work_date DATE);
    PROCEDURE load_raw_attendance(p_work_date DATE);
    PROCEDURE resolve_shift_for_emp(p_work_date DATE);
    PROCEDURE insert_daily_attendance(p_work_date DATE);
    PROCEDURE insert_moves;
    PROCEDURE last_out_engine;
    PROCEDURE mark_processed_raw;
    PROCEDURE update_work_minutes(p_work_date DATE);
    PROCEDURE calculate_additional_metrics(p_work_date DATE);
    PROCEDURE update_processed_flags(p_work_date DATE);
    PROCEDURE sync_with_absence_system(p_work_date DATE);
    PROCEDURE optimize_memory_10g;
    PROCEDURE cleanup_collections_10g;
    PROCEDURE quick_reprocess(p_work_date DATE);
    PROCEDURE reprocess_stuck_punches(p_work_date DATE);
    PROCEDURE diagnose_and_reprocess(p_work_date DATE);

    PROCEDURE COLLECT_violations(g_WORK_DATE DATE);
    PROCEDURE reprocess_with_next_day(p_work_date DATE);

END attend_eng_pkg;
/





create or replace PACKAGE BODY "ATTEND_ENG_PKG" IS
v_mid_idx NUMBER := 0;

TYPE classified_punch_rec IS RECORD(
emp_code      NUMBER,
punch_time    DATE,
work_date     DATE,
punch_status  VARCHAR2(10),
session_id    NUMBER,
shift_type    VARCHAR2(50)
);
TYPE classified_punch_tab IS TABLE OF classified_punch_rec INDEX BY PLS_INTEGER;
v_classified_punches classified_punch_tab;
v_classified_idx NUMBER := 0;

-- ==================== CALCULATE OVERTIME ====================
FUNCTION calculate_overtime(
p_first_in IN DATE, p_last_out IN DATE,
p_shift_start IN DATE, p_shift_end IN DATE,
p_is_night IN CHAR DEFAULT 'N',
p_shift_id IN NUMBER DEFAULT NULL
) RETURN NUMBER IS
v_overtime_min NUMBER := 0;
v_shift_duration NUMBER;
v_actual_work NUMBER;
v_effective_first_in DATE;
v_raw_late_min NUMBER;
v_allow_late_min NUMBER := 30;
BEGIN
IF p_first_in IS NULL OR p_last_out IS NULL THEN RETURN 0; END IF;

IF p_shift_id IS NOT NULL THEN
BEGIN
SELECT NVL(allow_late_min, 30) INTO v_allow_late_min
FROM att_emp_shift WHERE shift_id = p_shift_id;
EXCEPTION WHEN NO_DATA_FOUND THEN v_allow_late_min := 30;
END;
END IF;

v_raw_late_min := ROUND((p_first_in - p_shift_start) * 24 * 60);

IF v_raw_late_min > 0 AND v_raw_late_min <= v_allow_late_min THEN
v_effective_first_in := p_shift_start;
ELSE
v_effective_first_in := p_first_in;
END IF;

v_shift_duration := ROUND((p_shift_end - p_shift_start) * 24 * 60);
IF p_is_night = 'Y' AND p_last_out < v_effective_first_in THEN
v_actual_work := ROUND(((p_last_out + 1) - v_effective_first_in) * 24 * 60);
ELSE
v_actual_work := ROUND((p_last_out - v_effective_first_in) * 24 * 60);
END IF;
v_overtime_min := GREATEST(0, v_actual_work - v_shift_duration);
RETURN v_overtime_min;
END calculate_overtime;

-- ==================== CALCULATE LATE MINUTES ====================
FUNCTION calculate_late_minutes(
p_shift_start IN DATE,
p_first_in    IN DATE,
p_shift_id    IN NUMBER DEFAULT NULL
) RETURN NUMBER IS
v_late_min NUMBER := 0;
v_allow_late_min NUMBER := 30;
BEGIN
IF p_shift_id IS NOT NULL THEN
BEGIN
SELECT NVL(allow_late_min, 30) INTO v_allow_late_min
FROM att_emp_shift WHERE shift_id = p_shift_id;
EXCEPTION WHEN NO_DATA_FOUND THEN v_allow_late_min := 30;
END;
ELSE
v_allow_late_min := 30;
END IF;

IF p_first_in IS NOT NULL AND p_shift_start IS NOT NULL THEN
v_late_min := ROUND((p_first_in - p_shift_start) * 24 * 60);
IF v_late_min <= v_allow_late_min THEN
v_late_min := 0;
END IF;
END IF;

RETURN v_late_min;
END calculate_late_minutes;

-- ==================== CALCULATE EARLY OUT ====================
FUNCTION calculate_early_out(
    p_shift_end   IN DATE,
    p_last_out    IN DATE,
    p_shift_id    IN NUMBER DEFAULT NULL,
    p_is_night    IN CHAR DEFAULT 'N'
) RETURN NUMBER IS
    v_early_out NUMBER := 0;
    v_allow_early_min NUMBER := 30;
BEGIN
    IF p_last_out IS NULL OR p_shift_end IS NULL THEN RETURN 0; END IF;

    IF p_shift_id IS NOT NULL THEN
        BEGIN
            SELECT NVL(allow_early_min, 30) INTO v_allow_early_min
            FROM att_emp_shift WHERE shift_id = p_shift_id;
        EXCEPTION WHEN NO_DATA_FOUND THEN v_allow_early_min := 30;
        END;
    ELSE
        v_allow_early_min := 30;
    END IF;

    IF p_is_night = 'Y' AND p_last_out > p_shift_end THEN RETURN 0; END IF;

    IF p_last_out < p_shift_end THEN
        v_early_out := ROUND((p_shift_end - p_last_out) * 24 * 60);
        IF v_early_out <= v_allow_early_min THEN
            v_early_out := 0;
        END IF;
        RETURN GREATEST(v_early_out, 0);
    END IF;

    RETURN 0;
END calculate_early_out;

-- ==================== EARLY IN MINUTES ====================
FUNCTION early_in_min (
p_shift_start IN DATE,
p_first_in    IN DATE,
p_shift_id    IN NUMBER
) RETURN NUMBER IS
v_early_in NUMBER := 0;
v_allow_early_min NUMBER := 30;
BEGIN
IF p_first_in IS NULL OR p_shift_start IS NULL THEN RETURN 0; END IF;

IF p_shift_id IS NOT NULL THEN
BEGIN
SELECT NVL(allow_early_min, 30) INTO v_allow_early_min
FROM att_emp_shift WHERE shift_id = p_shift_id;
EXCEPTION WHEN NO_DATA_FOUND THEN v_allow_early_min := 30;
END;
END IF;

IF p_first_in < p_shift_start THEN
v_early_in := ROUND((p_shift_start - p_first_in) * 24 * 60);
IF v_early_in <= v_allow_early_min THEN v_early_in := 0; END IF;
ELSE
v_early_in := 0;
END IF;

RETURN v_early_in;
END early_in_min;

-- ==================== EARLY IN HOURS ====================
FUNCTION early_in_hours (
p_shift_start IN DATE,
p_first_in    IN DATE,
p_shift_id    IN NUMBER DEFAULT NULL
) RETURN NUMBER IS
v_minutes NUMBER := 0;
BEGIN
v_minutes := early_in_min(p_shift_start, p_first_in, p_shift_id);
RETURN ROUND(v_minutes / 60, 2);
END early_in_hours;

-- ==================== CALCULATE NIGHT SHIFT HOURS ====================
FUNCTION calculate_night_shift_hours(
p_first_in      IN DATE,
p_last_out      IN DATE,
p_shift_start   IN DATE,
p_shift_end     IN DATE,
p_night_start   IN NUMBER DEFAULT NULL,
p_night_end     IN NUMBER DEFAULT NULL
) RETURN NUMBER IS
v_night_minutes   NUMBER := 0;
v_start_date      DATE;
v_night_start_time DATE;
v_night_end_time  DATE;
v_temp_start      DATE;
v_temp_end        DATE;
v_night_start_hr  NUMBER;
v_night_end_hr    NUMBER;
v_conf_value      VARCHAR2(20);
BEGIN
IF p_first_in IS NULL OR p_last_out IS NULL THEN RETURN 0; END IF;

IF p_night_start IS NULL THEN
BEGIN
SELECT conf_value INTO v_conf_value
FROM att_gate_conf WHERE conf_key = 'NIGHT_GATE_START';
v_night_start_hr := TO_NUMBER(SUBSTR(v_conf_value, 1, 2))
+ (TO_NUMBER(SUBSTR(v_conf_value, 4, 2)) / 60);
EXCEPTION WHEN OTHERS THEN v_night_start_hr := 19;
END;
ELSE
v_night_start_hr := p_night_start;
END IF;

IF p_night_end IS NULL THEN
BEGIN
SELECT conf_value INTO v_conf_value
FROM att_gate_conf WHERE conf_key = 'NIGHT_GATE_END';
v_night_end_hr := TO_NUMBER(SUBSTR(v_conf_value, 1, 2))
+ (TO_NUMBER(SUBSTR(v_conf_value, 4, 2)) / 60);
EXCEPTION WHEN OTHERS THEN v_night_end_hr := 6.983;
END;
ELSE
v_night_end_hr := p_night_end;
END IF;

v_start_date := TRUNC(p_first_in);
v_night_start_time := v_start_date + (v_night_start_hr / 24);
v_night_end_time   := v_start_date + 1 + (v_night_end_hr / 24);

IF p_last_out < p_first_in THEN
v_temp_start := GREATEST(p_first_in, v_night_start_time);
v_temp_end := (TRUNC(p_last_out) + 1) + (p_last_out - TRUNC(p_last_out));
IF v_temp_end > v_temp_start THEN
v_night_minutes := (v_temp_end - v_temp_start) * 24 * 60;
END IF;
ELSE
v_temp_start := GREATEST(p_first_in, v_night_start_time);
v_temp_end := LEAST(p_last_out, v_night_end_time);
IF v_temp_end > v_temp_start THEN
v_night_minutes := (v_temp_end - v_temp_start) * 24 * 60;
END IF;
END IF;

RETURN ROUND(v_night_minutes);
EXCEPTION
WHEN OTHERS THEN RETURN 0;
END calculate_night_shift_hours;

-- ==================== DETERMINE ATTEND STATUS ====================
FUNCTION determine_attend_status(
p_work_min IN NUMBER,
p_late_min IN NUMBER,
p_first_in IN DATE,
p_last_out IN DATE,
p_emp_code IN NUMBER DEFAULT NULL
) RETURN VARCHAR2 IS
v_status VARCHAR2(20);
BEGIN
IF p_last_out IS NULL THEN RETURN 'INCOMPLETE'; END IF;

IF p_late_min > 60 THEN
v_status := 'LATE_SEVERE';
ELSIF p_work_min < 240 THEN
v_status := 'LATE_SEVERE';
ELSIF p_late_min > 0 THEN
v_status := 'LATE';
ELSE
v_status := 'PRESENT';
END IF;

RETURN v_status;
END determine_attend_status;

-- ==================== CALC WORK MIN ====================
FUNCTION calc_work_min(
p_shift_start IN DATE,
p_shift_end   IN DATE,
p_first_in    IN DATE,
p_last_out    IN DATE
) RETURN NUMBER IS
v_work_min NUMBER;
BEGIN
IF p_first_in IS NULL OR p_last_out IS NULL THEN RETURN 0; END IF;

v_work_min := (p_last_out - p_first_in) * 24 * 60;

IF p_last_out < p_first_in THEN
v_work_min := ((p_last_out + 1) - p_first_in) * 24 * 60;
END IF;

RETURN ROUND(GREATEST(v_work_min, 0));
END calc_work_min;

-- ==================== CALC WORK MIN HOURS ====================
FUNCTION calc_work_min_hours(
p_shift_start_hour IN NUMBER,
p_shift_end_hour   IN NUMBER,
p_first_in         IN DATE,
p_last_out         IN DATE,
p_work_date        IN DATE,
p_is_night         IN CHAR DEFAULT 'N'
) RETURN NUMBER IS
v_work_min NUMBER := 0;
BEGIN
IF p_first_in IS NOT NULL AND p_last_out IS NOT NULL THEN
IF p_last_out > p_first_in THEN
v_work_min := ROUND((p_last_out - p_first_in) * 24 * 60);
ELSIF p_is_night = 'Y' AND p_last_out < p_first_in THEN
v_work_min := ROUND(((p_last_out + 1) - p_first_in) * 24 * 60);
END IF;
END IF;

RETURN v_work_min;
END calc_work_min_hours;

-- ==================== RUN DAILY ATTENDANCE ====================
PROCEDURE run_daily_attendance(p_work_date DATE) IS
v_start_time DATE := SYSDATE;
v_end_time DATE;
v_duration NUMBER;
BEGIN
g_work_date := TRUNC(p_work_date);
g_step_name := 'STEP_RUN';

log_engine_step(g_step_name, 'Starting attendance processing for day ' ||
TO_CHAR(g_work_date, 'DD-MM-YYYY'), g_work_date);

lock_day(g_work_date);
load_raw_attendance(g_work_date);
resolve_shift_for_emp(g_work_date);
insert_daily_attendance(g_work_date);
BEGIN
    WARDIYA_DECIDED(g_work_date);
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        log_engine_step('WARDIYA_DECIDED_ERROR',
                        'Emp=ALL | ' || SQLERRM, g_work_date);
END;
update_work_minutes(g_work_date);
calculate_additional_metrics(g_work_date);
update_processed_flags(g_work_date);
sync_with_absence_system(g_work_date);
mark_processed_raw;
insert_moves;
COLLECT_violations(g_work_date);

v_end_time := SYSDATE;
v_duration := (v_end_time - v_start_time) * 24 * 60 * 60;

log_engine_step('STEP_RUN_COMPLETE',
'Attendance processing completed successfully | Duration: ' ||
ROUND(v_duration, 2) || ' seconds', g_work_date);

EXCEPTION
WHEN OTHERS THEN
log_engine_step('STEP_RUN_FATAL', 'Fatal error: ' || SQLERRM, g_work_date);
RAISE;
END run_daily_attendance;

-- ==================== LOG ENGINE STEP ====================
PROCEDURE log_engine_step(
p_step VARCHAR2,
p_msg VARCHAR2,
p_work_date DATE,
p_emp_code NUMBER DEFAULT NULL
) IS
PRAGMA AUTONOMOUS_TRANSACTION;
BEGIN
INSERT INTO emp_attend_log(
log_id, emp_code, log_date, log_step, log_message, work_date
) VALUES (
attend_log_seq.NEXTVAL, p_emp_code, SYSDATE, p_step, p_msg,
NVL(p_work_date, g_work_date)
);
COMMIT;
EXCEPTION
WHEN OTHERS THEN
NULL;
END log_engine_step;

-- ==================== LOCK DAY ====================
PROCEDURE lock_day(p_work_date DATE) IS
v_cnt NUMBER;
BEGIN
SELECT COUNT(*) INTO v_cnt
FROM attend_day_lock
WHERE work_date = TRUNC(p_work_date);

IF v_cnt = 0 THEN
INSERT INTO attend_day_lock(
work_date, status, locked_by, locked_at, notes
) VALUES (
TRUNC(p_work_date), 'L', 'ATTEND_ENG_PKG', SYSDATE,
'Locked for attendance processing'
);
COMMIT;
log_engine_step('DAY_LOCKED', 'Day locked successfully', p_work_date);
ELSE
RAISE_APPLICATION_ERROR(-20001,
'Day already locked: ' || TO_CHAR(p_work_date, 'DD-MM-YYYY'));
END IF;
END lock_day;

-- ==================== LOAD RAW ATTENDANCE ====================
PROCEDURE load_raw_attendance(p_work_date DATE) IS
v_with_code      NUMBER := 0;
v_without_code   NUMBER := 0;
v_start_date     DATE;
v_end_date       DATE;
BEGIN
v_tab.DELETE;

v_start_date := TRUNC(p_work_date);
v_end_date   := TRUNC(p_work_date) + 1;

log_engine_step('LOAD_RAW_START',
'Loading punches from ' || TO_CHAR(v_start_date, 'DD/MM/YYYY HH24:MI') ||
' to ' || TO_CHAR(v_end_date, 'DD/MM/YYYY HH24:MI'), p_work_date);

SELECT
a.emp_code, a.first_name, a.last_name, a.punch_time, a.weekday,
a.work_date, a.punch_status, a.file_name, a.process_flag, a.session_id
BULK COLLECT INTO v_tab
FROM attendance_staging a
WHERE a.process_flag = 'N'
AND (
TRUNC(a.punch_time) = TRUNC(p_work_date)
OR (TRUNC(a.punch_time) = TRUNC(p_work_date) - 1
AND TO_NUMBER(TO_CHAR(a.punch_time, 'HH24')) >= 18)
OR (TRUNC(a.punch_time) = TRUNC(p_work_date) + 1
AND TO_NUMBER(TO_CHAR(a.punch_time, 'HH24')) < 7)
)
ORDER BY a.emp_code, a.punch_time;

IF v_tab.COUNT > 0 THEN
DBMS_OUTPUT.PUT_LINE('========== DBG_LOAD_RAW ==========');
FOR i IN v_tab.FIRST .. v_tab.LAST LOOP
DBMS_OUTPUT.PUT_LINE('EMP=' || v_tab(i).emp_code ||
' | TIME=' || TO_CHAR(v_tab(i).punch_time, 'DD-MM HH24:MI:SS') ||
' | STATUS=' || v_tab(i).punch_status);
END LOOP;
DBMS_OUTPUT.PUT_LINE('================================');
END IF;

IF v_tab.COUNT > 0 THEN
FOR i IN 1 .. v_tab.COUNT LOOP
IF v_tab(i).emp_code IS NOT NULL THEN
v_with_code := v_with_code + 1;
ELSE
v_without_code := v_without_code + 1;
END IF;
END LOOP;
END IF;

log_engine_step('LOAD_RAW_COMPLETE',
'Loaded ' || v_tab.COUNT || ' punches' ||
' (With code: ' || v_with_code ||
', Without code: ' || v_without_code || ')', p_work_date);

EXCEPTION
WHEN OTHERS THEN
log_engine_step('LOAD_RAW_ERROR', SQLERRM, p_work_date);
RAISE;
END load_raw_attendance;

-- ==================== RESOLVE_SHIFT_FOR_EMP ====================
PROCEDURE resolve_shift_for_emp(p_work_date DATE) IS

v_idx                 PLS_INTEGER := 0;
v_is_admin            BOOLEAN := FALSE;
v_category            VARCHAR2(200);
v_first_in_hour       NUMBER;
v_new_first_in_hour   NUMBER;

v_min_double_shift_gap_minutes CONSTANT NUMBER := 120;
v_max_shift_hours              CONSTANT NUMBER := 17;
v_session_state       VARCHAR2(20) := 'NO_SESSION';
v_last_emp            NUMBER := -1;

v_session_first_in    DATE := NULL;
v_session_last_out    DATE := NULL;
v_session_work_date   DATE := NULL;

v_session_in_count    NUMBER := 0;
v_session_out_count   NUMBER := 0;
v_session_mid_count   NUMBER := 0;
v_session_punch_count NUMBER := 0;

v_session_id          NUMBER := 0;

v_last_punch_time     DATE := NULL;
v_temp_punch_time     DATE;

v_prev_open_found       BOOLEAN := FALSE;
v_prev_open_work_date   DATE := NULL;
v_prev_open_first_in    DATE := NULL;
v_prev_open_session_id  NUMBER := NULL;

v_shift_start_date       DATE := NULL;
v_shift_end_date         DATE := NULL;
v_ot_end_date            DATE := NULL;
v_shift_duration_minutes NUMBER := 0;
v_acceptance_end_date    DATE := NULL;
c_day_grace_hours  CONSTANT NUMBER := 7;
TYPE shift_temp_type IS RECORD (
shift_id          NUMBER,
shift_type        VARCHAR2(50),
start_hour        NUMBER,
end_hour          NUMBER,
is_night          CHAR(1),
shift_flag        NUMBER,
start_normalized  NUMBER
);
TYPE shift_temp_tab IS TABLE OF shift_temp_type INDEX BY PLS_INTEGER;
v_shifts shift_temp_tab;
v_shifts_count NUMBER := 0;
v_best_shift_local shift_temp_type;
v_new_shift_local  shift_temp_type;

-- FIX B: next_punch_time = the next punch that is NOT a duplicate.
-- Before: LEAD() was set to NULL when the next punch was < 5 min away, so a real
-- punch followed by its own device duplicate (09:51:00 / 09:51:48) looked like
-- the last punch of the day and closed the session too early.
CURSOR c_punches IS
SELECT emp_code, punch_time, punch_status, work_date, session_id,
MIN(CASE WHEN is_duplicate = 0 THEN punch_time END)
OVER (PARTITION BY emp_code
ORDER BY punch_time
ROWS BETWEEN 1 FOLLOWING AND UNBOUNDED FOLLOWING) AS next_punch_time,
prev_punch_time, punch_count_today,
is_duplicate
FROM (
SELECT emp_code, punch_time, punch_status, work_date, session_id,
prev_punch_time, punch_count_today,
CASE
WHEN prev_punch_time IS NOT NULL
AND ABS((punch_time - prev_punch_time) * 24 * 60) < 5
THEN 1
ELSE 0
END AS is_duplicate
FROM (
SELECT emp_code, punch_time, punch_status, work_date, session_id,
LAG(punch_time) OVER (PARTITION BY emp_code ORDER BY punch_time) AS prev_punch_time,
COUNT(*) OVER (PARTITION BY emp_code) AS punch_count_today
FROM (
SELECT emp_code, punch_time, punch_status, work_date, session_id,
ROW_NUMBER() OVER (
PARTITION BY emp_code, punch_time
ORDER BY CASE punch_status
WHEN 'OUT' THEN 1
WHEN 'MID' THEN 2
WHEN 'IN'  THEN 3
ELSE 4 END
) AS rn
FROM attendance_staging
WHERE process_flag = 'N'
AND (
TRUNC(punch_time) = TRUNC(p_work_date)
OR (TRUNC(punch_time) = TRUNC(p_work_date) - 1
AND TO_NUMBER(TO_CHAR(punch_time, 'HH24')) >= 18)
OR (TRUNC(punch_time) = TRUNC(p_work_date) + 1
AND TO_NUMBER(TO_CHAR(punch_time, 'HH24')) < 7)
)
)
WHERE rn = 1
)
)
ORDER BY emp_code, punch_time;

FUNCTION safe_hour(p_date DATE) RETURN NUMBER IS
BEGIN
IF p_date IS NULL THEN RETURN 0; END IF;
RETURN TO_NUMBER(TO_CHAR(p_date, 'HH24'));
EXCEPTION
WHEN OTHERS THEN RETURN 0;
END safe_hour;

FUNCTION safe_minute(p_date DATE) RETURN NUMBER IS
BEGIN
IF p_date IS NULL THEN RETURN 0; END IF;
RETURN TO_NUMBER(TO_CHAR(p_date, 'MI'));
EXCEPTION
WHEN OTHERS THEN RETURN 0;
END safe_minute;

-- Appends one classified punch (replaces ~15 copy-pasted blocks)
PROCEDURE add_classified(
p_emp_code   NUMBER,
p_punch_time DATE,
p_work_date  DATE,
p_status     VARCHAR2,
p_session_id NUMBER
) IS
BEGIN
v_classified_idx := v_classified_idx + 1;
v_classified_punches(v_classified_idx).emp_code     := p_emp_code;
v_classified_punches(v_classified_idx).punch_time   := p_punch_time;
v_classified_punches(v_classified_idx).work_date    := p_work_date;
v_classified_punches(v_classified_idx).punch_status := p_status;
v_classified_punches(v_classified_idx).session_id   := p_session_id;
END add_classified;

FUNCTION get_best_shift(p_first_in_hour NUMBER, p_is_admin BOOLEAN) RETURN shift_temp_type IS
v_result        shift_temp_type;
v_best_score    NUMBER := -999999;
v_current_score NUMBER;
v_shift_start   NUMBER;
v_shift_end     NUMBER;
v_inside_shift  BOOLEAN;
v_dist_start    NUMBER;
v_dist_end      NUMBER;
v_distance      NUMBER;
v_shift_flag    NUMBER;
BEGIN
v_result.shift_id := 0;
v_result.shift_type := 'DEF';
v_result.start_hour := 7;
v_result.end_hour := 15;
v_result.is_night := 'N';
v_result.shift_flag := 1;
v_result.start_normalized := 420;

IF v_shifts_count = 0 THEN RETURN v_result; END IF;

IF p_first_in_hour >= 4 AND p_first_in_hour < 11 THEN
v_shift_flag := 1;
ELSIF p_first_in_hour >= 12 AND p_first_in_hour < 18 THEN
v_shift_flag := 2;
ELSE
v_shift_flag := 3;
END IF;

FOR s IN 1 .. v_shifts_count LOOP

IF NVL(v_shifts(s).shift_flag, 0) != v_shift_flag THEN
GOTO next_shift;
END IF;

IF v_shift_flag = 2 THEN
IF p_first_in_hour >= 12.5 AND p_first_in_hour < 14.75
AND v_shifts(s).shift_type != 'EVE1' THEN
GOTO next_shift;
END IF;
IF p_first_in_hour >= 14.75 AND p_first_in_hour < 23
AND v_shifts(s).shift_type != 'EVE2' THEN
GOTO next_shift;
END IF;
END IF;

IF v_shift_flag = 3 THEN
IF p_first_in_hour >= 18 AND p_first_in_hour < 21
AND v_shifts(s).shift_type != 'NIGHT' THEN
GOTO next_shift;
END IF;
IF p_first_in_hour >= 21 AND p_first_in_hour < 22.7667
AND v_shifts(s).shift_type != 'NIGHT2' THEN
GOTO next_shift;
END IF;
IF (p_first_in_hour >= 22.7667 OR p_first_in_hour < 7)
AND v_shifts(s).shift_type != 'NIGHT3' THEN
GOTO next_shift;
END IF;
END IF;

v_current_score := 0;
v_inside_shift := FALSE;
v_shift_start := NVL(v_shifts(s).start_hour, 7);
v_shift_end   := NVL(v_shifts(s).end_hour, 15);

IF v_shift_end >= v_shift_start THEN
IF p_first_in_hour BETWEEN v_shift_start AND v_shift_end THEN
v_inside_shift := TRUE;
END IF;
ELSE
IF p_first_in_hour >= v_shift_start OR p_first_in_hour <= v_shift_end THEN
v_inside_shift := TRUE;
END IF;
END IF;

IF v_inside_shift THEN
v_current_score := v_current_score + 100;
END IF;

IF p_first_in_hour >= v_shift_start THEN
v_dist_start := LEAST(p_first_in_hour - v_shift_start,
24 - (p_first_in_hour - v_shift_start));
ELSE
v_dist_start := LEAST(v_shift_start - p_first_in_hour,
24 - (v_shift_start - p_first_in_hour));
END IF;

IF p_first_in_hour >= v_shift_end THEN
v_dist_end := LEAST(p_first_in_hour - v_shift_end,
24 - (p_first_in_hour - v_shift_end));
ELSE
v_dist_end := LEAST(v_shift_end - p_first_in_hour,
24 - (v_shift_end - p_first_in_hour));
END IF;

v_distance := LEAST(v_dist_start, v_dist_end);

IF v_distance <= 1 THEN v_current_score := v_current_score + 100;
ELSIF v_distance <= 2 THEN v_current_score := v_current_score + 50;
ELSIF v_distance <= 4 THEN v_current_score := v_current_score + 20;
ELSE v_current_score := v_current_score - (v_distance * 2);
END IF;

IF p_first_in_hour >= v_shift_start - 2 AND p_first_in_hour < v_shift_start THEN
v_current_score := v_current_score + 300;
END IF;

IF NOT p_is_admin AND NVL(v_shifts(s).shift_type, 'DEF') = 'MOR'
AND p_first_in_hour BETWEEN 6 AND 13 THEN
v_current_score := v_current_score + 60;
END IF;

IF NOT p_is_admin AND NVL(v_shifts(s).shift_type, 'DEF') = 'EVE1'
AND p_first_in_hour BETWEEN 13 AND 15 THEN
v_current_score := v_current_score + 90;
END IF;

IF NOT p_is_admin AND NVL(v_shifts(s).shift_type, 'DEF') = 'EVE2'
AND p_first_in_hour BETWEEN 15 AND 18 THEN
v_current_score := v_current_score + 90;
END IF;

IF NOT p_is_admin AND NVL(v_shifts(s).shift_type, 'DEF') = 'ADM' THEN
v_current_score := v_current_score - 200;
END IF;
IF p_is_admin AND NVL(v_shifts(s).shift_type, 'DEF') = 'ADM' THEN
v_current_score := v_current_score + 80;
END IF;

IF NVL(v_shifts(s).is_night, 'N') = 'Y' AND v_inside_shift THEN
v_current_score := v_current_score + 5;
END IF;

IF NVL(v_shifts(s).shift_type, 'DEF') <> 'DEF' THEN
v_current_score := v_current_score + 10;
END IF;

IF v_current_score > v_best_score THEN
v_best_score := v_current_score;
v_result := v_shifts(s);
END IF;

<<next_shift>>
NULL;
END LOOP;

RETURN v_result;
END get_best_shift;

PROCEDURE calculate_session_limits(p_first_in DATE) IS
BEGIN
IF NVL(v_best_shift_local.is_night, 'N') = 'Y'
AND safe_hour(p_first_in) <= NVL(v_best_shift_local.end_hour, 6) THEN
v_shift_start_date := TRUNC(p_first_in) - 1
+ (NVL(v_best_shift_local.start_hour, 19) / 24);
v_shift_end_date := TRUNC(p_first_in)
+ (NVL(v_best_shift_local.end_hour, 6) / 24);
ELSE
v_shift_start_date := TRUNC(p_first_in)
+ (NVL(v_best_shift_local.start_hour, 7) / 24);

IF NVL(v_best_shift_local.is_night, 'N') = 'Y'
AND NVL(v_best_shift_local.end_hour, 15) < NVL(v_best_shift_local.start_hour, 7) THEN
v_shift_end_date := TRUNC(p_first_in) + 1
+ (NVL(v_best_shift_local.end_hour, 6) / 24);
ELSE
v_shift_end_date := TRUNC(p_first_in)
+ (NVL(v_best_shift_local.end_hour, 15) / 24);
END IF;
END IF;

v_shift_duration_minutes := ROUND((v_shift_end_date - v_shift_start_date) * 1440);
v_ot_end_date := v_shift_end_date + (v_shift_duration_minutes / 1440);

IF NVL(v_best_shift_local.is_night, 'N') = 'N' THEN
-- ? ?????/?????: ????? ?????? + 7 ?????? ????? ???? ?????? ?????
v_acceptance_end_date := LEAST(
v_shift_end_date + c_day_grace_hours / 24,
TRUNC(p_first_in) + 1
);
ELSE
-- ? ??????: ????? ?????? + 7 ????? (???? ????? ???)
v_acceptance_end_date := v_shift_end_date + c_day_grace_hours / 24;
END IF;
END calculate_session_limits;
PROCEDURE close_previous_open_night (
p_emp_code   NUMBER,
p_punch_time DATE,
p_days_back  NUMBER DEFAULT 1
) IS
v_work_date      DATE;
v_first_in       DATE;
v_session_id     NUMBER;
v_work_min       NUMBER;
v_shift_id       NUMBER;
v_shift_start    DATE;
v_shift_end      DATE;
v_start_hour     NUMBER;
v_end_hour       NUMBER;
v_is_night       CHAR(1);
v_late_min       NUMBER;
v_early_min      NUMBER;
v_ot_min         NUMBER;
v_status         VARCHAR2(20);
v_night_work_min NUMBER := 0;
v_night_work_hour NUMBER := 0;
v_punch_hr       NUMBER;
BEGIN
v_prev_open_found      := FALSE;
v_prev_open_work_date  := NULL;
v_prev_open_first_in   := NULL;
v_prev_open_session_id := NULL;
 
v_punch_hr := safe_hour(p_punch_time) + (safe_minute(p_punch_time) / 60);
 
BEGIN
SELECT d.work_date, d.first_in, d.shift_id
INTO   v_work_date, v_first_in, v_shift_id
FROM (
SELECT d.work_date, d.first_in, d.shift_id
FROM emp_attend_daily d
LEFT JOIN att_emp_shift s ON d.shift_id = s.shift_id
WHERE d.emp_code = p_emp_code
AND TRUNC(d.work_date) >= TRUNC(p_punch_time) - p_days_back
AND TRUNC(d.work_date) <  TRUNC(p_punch_time)
AND (
(s.shift_flag = 3)                              -- ? ???? ??
OR
(d.shift_id = 0                                 -- ? ???? ????? ?????? ?? ?????? (12-18) ????? ?????? ??? ????? ?????
AND (TO_NUMBER(TO_CHAR(d.first_in, 'HH24')) >= 18
OR TO_NUMBER(TO_CHAR(d.first_in, 'HH24')) < 5
OR (TO_NUMBER(TO_CHAR(d.first_in, 'HH24')) >= 12 AND v_punch_hr < 5)))   -- [????] ???? ??? ????? + ???? ??? ????? ?????
)
AND d.first_in IS NOT NULL
AND d.last_out IS NULL
AND p_punch_time > d.first_in
AND (p_punch_time - d.first_in) * 24 < v_max_shift_hours
              AND (
                    (s.shift_flag = 3 AND (v_punch_hr >= 18 OR v_punch_hr < 9))
                    OR
                    (d.shift_id = 0
                     AND p_punch_time <= TRUNC(d.first_in)
                         + CASE WHEN TO_NUMBER(TO_CHAR(d.first_in, 'HH24')) >= 12
                                THEN 1 ELSE 0 END
                         + (7 + c_day_grace_hours) / 24)   -- ????? ?????? 07:00 + 7 = 14:00
                  )
ORDER BY d.first_in DESC
) d
WHERE ROWNUM = 1;
EXCEPTION
WHEN NO_DATA_FOUND THEN
v_prev_open_found := FALSE;
RETURN;
END;
 
IF v_shift_id = 0 THEN
DECLARE
v_first_hour NUMBER := TO_NUMBER(TO_CHAR(v_first_in, 'HH24'))
+ (TO_NUMBER(TO_CHAR(v_first_in, 'MI')) / 60);
BEGIN
IF v_first_hour >= 12 AND v_first_hour < 14.75 THEN   -- [????]
SELECT shift_id INTO v_shift_id FROM att_emp_shift WHERE shift_type = 'EVE1' AND ROWNUM = 1;
ELSIF v_first_hour >= 14.75 AND v_first_hour < 18 THEN   -- [????]
SELECT shift_id INTO v_shift_id FROM att_emp_shift WHERE shift_type = 'EVE2' AND ROWNUM = 1;
ELSIF v_first_hour >= 18 AND v_first_hour < 21 THEN
SELECT shift_id INTO v_shift_id FROM att_emp_shift WHERE shift_type = 'NIGHT' AND ROWNUM = 1;
ELSIF v_first_hour >= 21 AND v_first_hour < 22.7667 THEN
SELECT shift_id INTO v_shift_id FROM att_emp_shift WHERE shift_type = 'NIGHT2' AND ROWNUM = 1;
ELSE
SELECT shift_id INTO v_shift_id FROM att_emp_shift WHERE shift_type = 'NIGHT3' AND ROWNUM = 1;
END IF;
EXCEPTION WHEN NO_DATA_FOUND THEN NULL;
END;
END IF;
 
BEGIN
SELECT session_id INTO v_session_id
FROM (
SELECT session_id FROM attendance_staging
WHERE emp_code = p_emp_code AND punch_time = v_first_in AND punch_status = 'IN'
ORDER BY session_id DESC
) WHERE ROWNUM = 1;
EXCEPTION
WHEN NO_DATA_FOUND THEN v_session_id := NULL;
END;
 
v_prev_open_found      := TRUE;
v_prev_open_work_date  := v_work_date;
v_prev_open_first_in   := v_first_in;
v_prev_open_session_id := v_session_id;
 
BEGIN
SELECT start_time, end_time, is_night
INTO v_shift_start, v_shift_end, v_is_night
FROM att_emp_shift WHERE shift_id = v_shift_id;
 
v_start_hour := TO_NUMBER(TO_CHAR(v_shift_start,'HH24')) + (TO_NUMBER(TO_CHAR(v_shift_start,'MI'))/60);
v_end_hour   := TO_NUMBER(TO_CHAR(v_shift_end,'HH24'))   + (TO_NUMBER(TO_CHAR(v_shift_end,'MI'))/60);
 
v_shift_start := TRUNC(v_first_in) + (v_start_hour/24);
IF v_is_night = 'Y' AND v_end_hour < v_start_hour THEN
v_shift_end := TRUNC(v_first_in) + 1 + (v_end_hour/24);
ELSE
v_shift_end := TRUNC(v_first_in) + (v_end_hour/24);
END IF;
EXCEPTION
WHEN NO_DATA_FOUND THEN
v_late_min := 0; v_early_min := 0; v_ot_min := 0; v_status := 'PRESENT';
END;
 
IF v_is_night = 'Y' THEN
v_work_min := ROUND((v_shift_end - v_shift_start) * 1440);
ELSE
v_work_min := ROUND((p_punch_time - v_first_in) * 1440);
END IF;
 
v_late_min  := calculate_late_minutes(v_shift_start, v_first_in, v_shift_id);
v_early_min := calculate_early_out(v_shift_end, p_punch_time, v_shift_id, v_is_night);
v_ot_min    := calculate_overtime(v_first_in, p_punch_time, v_shift_start, v_shift_end, v_is_night, v_shift_id);
v_status    := determine_attend_status(v_work_min, v_late_min, v_first_in, p_punch_time);
 
v_night_work_min := calculate_night_shift_hours(v_first_in, p_punch_time, v_shift_start, v_shift_end);
v_night_work_hour := ROUND(v_night_work_min / 60, 2);
 
UPDATE emp_attend_daily
SET last_out       = p_punch_time,
work_min       = v_work_min,
total_hours    = ROUND(v_work_min / 60, 2),
raw_punch_count = 2,
shift_id       = v_shift_id,
shift_type     = (SELECT shift_type FROM att_emp_shift WHERE shift_id = v_shift_id),
attend_status  = v_status,
late_min       = v_late_min,
early_out_min  = v_early_min,
overtime_min   = v_ot_min,
late_hours     = ROUND(v_late_min/60, 2),
early_out_hours= ROUND(v_early_min/60, 2),
overtime_hours = ROUND(v_ot_min/60, 2),
night_work_min = v_night_work_min,
night_work_hour= v_night_work_hour,
notes          = 'Punches: 2 (IN: 1, OUT: 1, MID: 0) | Shift: '
|| (SELECT shift_type FROM att_emp_shift WHERE shift_id = v_shift_id)
|| ' (' || TO_CHAR(v_shift_start, 'HH24:MI') || '-'
|| TO_CHAR(v_shift_end, 'HH24:MI') || ')'
|| CASE WHEN v_is_night = 'Y' THEN ' Night' ELSE '' END
|| ' | First: ' || TO_CHAR(v_first_in, 'HH24:MI')
|| ' | Last: ' || TO_CHAR(p_punch_time, 'HH24:MI')
|| ' | RECONCILED',
process_flag   = 'N',
updated_at     = SYSDATE,
updated_by     = 'ATTEND_ENG_NIGHT_CLOSE'
WHERE emp_code = p_emp_code
AND TRUNC(work_date) = TRUNC(v_prev_open_work_date)
AND (shift_id = v_shift_id OR shift_id = 0)
AND last_out IS NULL;
END close_previous_open_night;

PROCEDURE close_same_day_morning_session (
p_emp_code   NUMBER,
p_punch_time DATE
) IS
v_work_date   DATE;
v_first_in    DATE;
v_shift_id    NUMBER;
v_shift_type  VARCHAR2(50);
v_session_id  NUMBER;
v_st          DATE;
v_en          DATE;
v_shift_start DATE;
v_shift_end   DATE;
v_work_min    NUMBER;
v_late_min    NUMBER;
v_early_min   NUMBER;
v_ot_min      NUMBER;
v_status      VARCHAR2(20);
BEGIN
v_prev_open_found      := FALSE;
v_prev_open_work_date  := NULL;
v_prev_open_first_in   := NULL;
v_prev_open_session_id := NULL;

-- 1) ???? ????? (05-12) ???? ?????? ?? ??? ????? ???? ?????
BEGIN
SELECT d.work_date, d.first_in
INTO   v_work_date, v_first_in
FROM (
SELECT d.work_date, d.first_in
FROM emp_attend_daily d
WHERE d.emp_code = p_emp_code
AND TRUNC(d.work_date) = TRUNC(p_punch_time)
AND (d.shift_id = 0 OR d.shift_type IN ('MOR','MOR2','ADM'))
AND d.first_in IS NOT NULL
AND d.last_out IS NULL
AND TO_NUMBER(TO_CHAR(d.first_in,'HH24')) >= 5
AND TO_NUMBER(TO_CHAR(d.first_in,'HH24')) < 12
AND p_punch_time > d.first_in
ORDER BY d.first_in DESC
) d
WHERE ROWNUM = 1;
EXCEPTION
WHEN NO_DATA_FOUND THEN
RETURN;
END;

-- 2) ????? ??????
v_shift_type := CASE
WHEN v_is_admin THEN 'ADM'
WHEN safe_hour(p_punch_time) * 60 + safe_minute(p_punch_time) < 14*60 + 59 THEN 'MOR2'
ELSE 'MOR' END;

SELECT shift_id, start_time, end_time
INTO   v_shift_id, v_st, v_en
FROM att_emp_shift
WHERE shift_type = v_shift_type AND ROWNUM = 1;

v_shift_start := TRUNC(v_first_in) + (safe_hour(v_st) + safe_minute(v_st) / 60) / 24;
v_shift_end   := TRUNC(v_first_in) + (safe_hour(v_en) + safe_minute(v_en) / 60) / 24;

BEGIN
SELECT session_id INTO v_session_id FROM (
SELECT session_id FROM attendance_staging
WHERE emp_code = p_emp_code AND punch_time = v_first_in AND punch_status = 'IN'
ORDER BY session_id DESC) WHERE ROWNUM = 1;
EXCEPTION WHEN NO_DATA_FOUND THEN v_session_id := NULL;
END;

v_prev_open_found      := TRUE;
v_prev_open_work_date  := v_work_date;
v_prev_open_first_in   := v_first_in;
v_prev_open_session_id := v_session_id;

v_work_min  := ROUND((p_punch_time - v_first_in) * 1440);
v_late_min  := calculate_late_minutes(v_shift_start, v_first_in, v_shift_id);
v_early_min := calculate_early_out(v_shift_end, p_punch_time, v_shift_id, 'N');
v_ot_min    := calculate_overtime(v_first_in, p_punch_time, v_shift_start, v_shift_end, 'N', v_shift_id);
v_status    := determine_attend_status(v_work_min, v_late_min, v_first_in, p_punch_time);

UPDATE emp_attend_daily
SET last_out = p_punch_time, shift_id = v_shift_id, shift_type = v_shift_type, is_night = 'N',
work_min = v_work_min, total_hours = ROUND(v_work_min/60, 2), raw_punch_count = 2,
attend_status = v_status, late_min = v_late_min, early_out_min = v_early_min,
overtime_min = v_ot_min, late_hours = ROUND(v_late_min/60, 2),
early_out_hours = ROUND(v_early_min/60, 2), overtime_hours = ROUND(v_ot_min/60, 2),
notes = NVL(notes,'') || ' | Closed same-day by punch ' || TO_CHAR(p_punch_time,'HH24:MI'),
process_flag = 'N', updated_at = SYSDATE, updated_by = 'ATTEND_ENG_MOR_CLOSE'
WHERE emp_code = p_emp_code
AND TRUNC(work_date) = TRUNC(v_work_date)
AND first_in = v_first_in
AND last_out IS NULL;
END close_same_day_morning_session;

FUNCTION is_likely_new_session(
p_punch_time        DATE,
p_prev_punch_time   DATE,
p_session_shift     shift_temp_type,
p_session_shift_end DATE
) RETURN BOOLEAN IS
v_punch_hour       NUMBER;
v_shift_start      NUMBER;
v_new_shift        shift_temp_type;
v_after_shift_end  BOOLEAN := FALSE;
v_near_new_start   BOOLEAN := FALSE;
v_gap_minutes      NUMBER := 9999;
BEGIN
v_punch_hour := safe_hour(p_punch_time) + (safe_minute(p_punch_time) / 60);
v_new_shift := get_best_shift(v_punch_hour, v_is_admin);
v_shift_start := NVL(v_new_shift.start_hour, 7);

IF p_prev_punch_time IS NOT NULL THEN
v_gap_minutes := (p_punch_time - p_prev_punch_time) * 24 * 60;
END IF;

IF p_session_shift_end IS NOT NULL AND p_punch_time > p_session_shift_end THEN
v_after_shift_end := TRUE;
END IF;

IF v_punch_hour BETWEEN (v_shift_start - 2) AND (v_shift_start + 2) THEN
v_near_new_start := TRUE;
END IF;

IF v_after_shift_end AND v_near_new_start
AND v_gap_minutes >= v_min_double_shift_gap_minutes THEN
RETURN TRUE;
END IF;

RETURN FALSE;
END is_likely_new_session;

PROCEDURE save_session IS
BEGIN
IF v_session_first_in IS NULL THEN RETURN; END IF;

IF v_session_last_out IS NOT NULL THEN
IF (v_session_last_out - v_session_first_in) * 24 * 60 < 1 THEN
RETURN;
END IF;
END IF;

IF v_session_last_out IS NOT NULL THEN
v_session_punch_count := NVL(v_session_in_count, 0) + NVL(v_session_mid_count, 0) + NVL(v_session_out_count, 0);
ELSE
v_session_punch_count := NVL(v_session_in_count, 0) + NVL(v_session_mid_count, 0);
END IF;

IF v_best_shift_local.shift_flag = 1 THEN
IF v_is_admin THEN
v_best_shift_local.shift_type := 'ADM';
v_best_shift_local.shift_id := 207;
v_best_shift_local.start_hour := 8;
v_best_shift_local.end_hour := 15;
ELSE
IF v_session_last_out IS NULL THEN
v_best_shift_local.shift_type := 'MOR';
v_best_shift_local.shift_id := 206;
v_best_shift_local.start_hour := 7;
v_best_shift_local.end_hour := 15;
ELSE
IF (TO_NUMBER(TO_CHAR(v_session_last_out, 'HH24')) * 60
+ TO_NUMBER(TO_CHAR(v_session_last_out, 'MI'))) < (14 * 60 + 59) THEN
v_best_shift_local.shift_type := 'MOR2';
v_best_shift_local.shift_id := 213;
v_best_shift_local.start_hour := 7;
v_best_shift_local.end_hour := 14;
ELSE
v_best_shift_local.shift_type := 'MOR';
v_best_shift_local.shift_id := 206;
v_best_shift_local.start_hour := 7;
v_best_shift_local.end_hour := 15;
END IF;
END IF;
END IF;
END IF;

v_idx := v_shift.COUNT + 1;
v_shift(v_idx).emp_code := NVL(v_last_emp, 0);
v_shift(v_idx).work_date := NVL(v_session_work_date, TRUNC(v_session_first_in));
v_shift(v_idx).shift_id := NVL(v_best_shift_local.shift_id, 0);
v_shift(v_idx).shift_type := NVL(v_best_shift_local.shift_type, 'DEF');
v_shift(v_idx).start_time := NVL(v_best_shift_local.start_hour, 7);
v_shift(v_idx).end_time := NVL(v_best_shift_local.end_hour, 15);
v_shift(v_idx).is_night := NVL(v_best_shift_local.is_night, 'N');
v_shift(v_idx).first_in := v_session_first_in;
v_shift(v_idx).last_out := v_session_last_out;
v_shift(v_idx).punch_count := v_session_punch_count;
v_shift(v_idx).in_count := NVL(v_session_in_count, 0);
v_shift(v_idx).out_count := NVL(v_session_out_count, 0);
v_shift(v_idx).mid_count := NVL(v_session_mid_count, 0);
v_shift(v_idx).session_id := NVL(v_session_id, 0);
END save_session;

BEGIN
v_shift.DELETE;
v_mid_collection.DELETE;
v_classified_punches.DELETE;
v_mid_idx := 0;
v_classified_idx := 0;
v_shifts.DELETE;
v_shifts_count := 0;
v_last_emp := -1;
v_session_id := 0;
v_session_state := 'NO_SESSION';
v_shift_start_date := NULL;
v_shift_end_date := NULL;
v_ot_end_date := NULL;
v_acceptance_end_date := NULL;
v_shift_duration_minutes := 0;

FOR rec IN (
SELECT shift_id, shift_type,
TO_NUMBER(TO_CHAR(start_time, 'HH24')) + (TO_NUMBER(TO_CHAR(start_time, 'MI')) / 60) AS start_hour,
TO_NUMBER(TO_CHAR(end_time, 'HH24')) + (TO_NUMBER(TO_CHAR(end_time, 'MI')) / 60) AS end_hour,
is_night,
shift_flag
FROM att_emp_shift
WHERE active_flag = 'Y'
ORDER BY start_hour
) LOOP
v_shifts_count := v_shifts_count + 1;
v_shifts(v_shifts_count).shift_id := NVL(rec.shift_id, 0);
v_shifts(v_shifts_count).shift_type := NVL(rec.shift_type, 'DEF');
v_shifts(v_shifts_count).start_hour := NVL(rec.start_hour, 7);
v_shifts(v_shifts_count).end_hour := NVL(rec.end_hour, 15);
v_shifts(v_shifts_count).is_night := NVL(rec.is_night, 'N');
v_shifts(v_shifts_count).shift_flag := NVL(rec.shift_flag, 1);
v_shifts(v_shifts_count).start_normalized := NVL(rec.start_hour, 7) * 60;
END LOOP;

FOR rec IN c_punches LOOP
v_temp_punch_time := rec.punch_time;

IF v_last_emp != rec.emp_code THEN
IF v_session_state = 'OPEN' AND v_session_first_in IS NOT NULL THEN
save_session;
END IF;

v_last_emp := rec.emp_code;
v_session_id := v_session_id + 1;

v_session_state := 'NO_SESSION';
v_session_first_in := NULL;
v_session_last_out := NULL;
v_session_work_date := NULL;
v_session_in_count := 0;
v_session_out_count := 0;
v_session_mid_count := 0;
v_session_punch_count := 0;
v_last_punch_time := NULL;

BEGIN
SELECT dept_name INTO v_category
FROM emp_import
WHERE emp_code = rec.emp_code AND ROWNUM = 1;

v_is_admin := (
v_category LIKE '%????? ?. ?????? ?????%'
OR v_category LIKE '%????? ?. ????? ???????%'
OR v_category LIKE '%?.???? ???? ???????%'
OR v_category LIKE '%?????? ???????? ???????%'
OR v_category LIKE '%????? ????????%'
OR v_category LIKE '%????????%'
OR v_category LIKE '%????????%'
OR v_category LIKE '%???????%'
OR v_category LIKE '%????????%'
OR v_category LIKE '%????????%'
OR v_category LIKE '%???????%'
OR v_category LIKE '%???????%'
OR v_category LIKE '%??????? ?????%'
OR v_category LIKE '%??????? ??????%'
OR v_category LIKE '%?????? ???????%'
OR v_category LIKE '%?????? ?????%'
OR v_category LIKE '%???????%'
OR v_category LIKE '%????? ????%'
OR v_category LIKE '%????? ????%'
OR v_category LIKE '%????????? ????????%'
OR v_category LIKE '%?????? ????%'
OR v_category LIKE '%????? ??????%'
OR v_category LIKE '%????? ?????%'
OR v_category LIKE '%?????? ?????%'
OR v_category LIKE '%?????? ???????%'
OR v_category LIKE '%?????%'
OR v_category LIKE '%????? ??????? ????%'
OR v_category LIKE '%??????? ?????????%'
OR v_category LIKE '%??????? ????????%'
OR v_category LIKE '%???? ???????%'
OR v_category LIKE '%?????? ????????%'
OR v_category LIKE '%?????? ?????%'
);
EXCEPTION
WHEN NO_DATA_FOUND THEN
v_is_admin := FALSE;
END;
END IF;

IF rec.is_duplicate = 1 THEN
add_classified(rec.emp_code, v_temp_punch_time, TRUNC(v_temp_punch_time), 'DUP', v_session_id);
CONTINUE;
END IF;

IF v_session_state = 'NO_SESSION' THEN

-- ???????????????????????????????????????????????????
-- 1) close_previous_open_night (NIGHT/EVE ?? ???)
-- ???????????????????????????????????????????????????
close_previous_open_night(
p_emp_code   => rec.emp_code,
p_punch_time => v_temp_punch_time,
p_days_back  => 1
);

IF v_prev_open_found THEN
v_last_punch_time := v_temp_punch_time;

add_classified(rec.emp_code, v_temp_punch_time, v_prev_open_work_date, 'OUT', v_prev_open_session_id);

DBMS_OUTPUT.PUT_LINE(
'  -> PREVIOUS NIGHT OUT'
|| ' | Emp=' || rec.emp_code
|| ' | Time=' || TO_CHAR(v_temp_punch_time, 'DD-MM-YYYY HH24:MI:SS')
|| ' | PreviousWorkDate=' || TO_CHAR(v_prev_open_work_date, 'DD-MM-YYYY')
);

CONTINUE;
END IF;

-- ???????????????????????????????????????????????????
-- 2) ? PATCH MOR: ???? ????? ? close_same_day_morning_session
-- ???????????????????????????????????????????????????
DECLARE
v_punch_hr NUMBER := safe_hour(v_temp_punch_time)
+ (safe_minute(v_temp_punch_time) / 60);
BEGIN
IF v_punch_hr >= 12 AND v_punch_hr < 18 THEN
close_same_day_morning_session(
p_emp_code   => rec.emp_code,
p_punch_time => v_temp_punch_time
);

IF v_prev_open_found THEN
v_last_punch_time := v_temp_punch_time;

add_classified(rec.emp_code, v_temp_punch_time, v_prev_open_work_date, 'OUT', v_prev_open_session_id);

DBMS_OUTPUT.PUT_LINE(
'  -> EVENING AS OUT (same-day MOR found)'
|| ' | Emp=' || rec.emp_code
|| ' | Time=' || TO_CHAR(v_temp_punch_time, 'DD-MM-YYYY HH24:MI:SS')
|| ' | ClosedWorkDate=' || TO_CHAR(v_prev_open_work_date, 'DD-MM-YYYY')
);

log_engine_step('EVENING_AS_OUT',
'Emp=' || rec.emp_code ||
' | Punch=' || TO_CHAR(v_temp_punch_time, 'DD-MM-YYYY HH24:MI') ||
' | Closed=' || TO_CHAR(v_prev_open_work_date, 'DD-MM-YYYY'),
v_prev_open_work_date, rec.emp_code);

CONTINUE;
END IF;
END IF;
END;

-- ???????????????????????????????????????????????????
-- 3) PATCH 1: ???? ??? ????? ????? (00:00-05:00) ? NIGHT OUT
-- ???????????????????????????????????????????????????
DECLARE
v_punch_hr NUMBER := safe_hour(v_temp_punch_time)
+ (safe_minute(v_temp_punch_time) / 60);
BEGIN
IF v_punch_hr >= 0 AND v_punch_hr < 5 THEN
close_previous_open_night(
p_emp_code   => rec.emp_code,
p_punch_time => v_temp_punch_time,
p_days_back  => 1
);

IF v_prev_open_found THEN
v_last_punch_time := v_temp_punch_time;

add_classified(rec.emp_code, v_temp_punch_time, v_prev_open_work_date, 'OUT', v_prev_open_session_id);

DBMS_OUTPUT.PUT_LINE(
'  -> NIGHT OUT (early morning)'
|| ' | Emp=' || rec.emp_code
|| ' | Time=' || TO_CHAR(v_temp_punch_time, 'DD-MM-YYYY HH24:MI:SS')
);

log_engine_step('NIGHT_EARLY_MORNING_OUT',
'Emp=' || rec.emp_code ||
' | Punch=' || TO_CHAR(v_temp_punch_time, 'DD-MM-YYYY HH24:MI'),
v_prev_open_work_date, rec.emp_code);

CONTINUE;
END IF;
END IF;
END;

-- ???????????????????????????????????????????????????
-- 4) ???? ???? ? ?????
-- ???????????????????????????????????????????????????
IF TRUNC(v_temp_punch_time) > TRUNC(p_work_date) THEN
CONTINUE;
END IF;

-- ???????????????????????????????????????????????????
-- 5) ??? ???? ????? (IN)
-- ???????????????????????????????????????????????????
v_session_state := 'OPEN';

v_session_first_in := v_temp_punch_time;
v_session_work_date := TRUNC(v_temp_punch_time);
v_session_in_count := 1;
v_session_punch_count := 1;
v_session_last_out := NULL;

v_first_in_hour := safe_hour(v_session_first_in) + (safe_minute(v_session_first_in) / 60);
v_best_shift_local := get_best_shift(v_first_in_hour, v_is_admin);

calculate_session_limits(v_session_first_in);

v_last_punch_time := v_temp_punch_time;

add_classified(rec.emp_code, v_temp_punch_time, TRUNC(v_temp_punch_time), 'IN', v_session_id);

CONTINUE;
END IF;

-- ==================== SESSION OPEN ====================
IF v_session_state = 'OPEN' THEN

IF v_temp_punch_time > v_acceptance_end_date THEN

IF TRUNC(v_temp_punch_time) > TRUNC(v_session_work_date) THEN

IF TRUNC(v_temp_punch_time) > TRUNC(p_work_date) THEN
CONTINUE;
END IF;

save_session;

v_session_id := v_session_id + 1;
v_session_state := 'OPEN';
v_session_first_in := v_temp_punch_time;
v_session_last_out := NULL;
v_session_work_date := TRUNC(v_temp_punch_time);
v_session_in_count := 1;
v_session_out_count := 0;
v_session_mid_count := 0;
v_session_punch_count := 1;
v_last_punch_time := v_temp_punch_time;

v_new_first_in_hour := safe_hour(v_temp_punch_time) + (safe_minute(v_temp_punch_time) / 60);
v_best_shift_local := get_best_shift(v_new_first_in_hour, v_is_admin);

calculate_session_limits(v_session_first_in);

add_classified(rec.emp_code, v_temp_punch_time, TRUNC(v_temp_punch_time), 'IN', v_session_id);

CONTINUE;
END IF;

add_classified(rec.emp_code, v_temp_punch_time, TRUNC(v_temp_punch_time), 'EXCEPTION', v_session_id);

CONTINUE;
END IF;

IF rec.next_punch_time IS NOT NULL
AND rec.next_punch_time <= v_acceptance_end_date
THEN
v_session_mid_count := v_session_mid_count + 1;
v_session_punch_count := v_session_punch_count + 1;
v_last_punch_time := v_temp_punch_time;

v_mid_idx := v_mid_idx + 1;
v_mid_collection(v_mid_idx).emp_code := rec.emp_code;
v_mid_collection(v_mid_idx).punch_time := v_temp_punch_time;
v_mid_collection(v_mid_idx).work_date := TRUNC(v_temp_punch_time);
v_mid_collection(v_mid_idx).session_id := v_session_id;
v_mid_collection(v_mid_idx).shift_type := v_best_shift_local.shift_type;

add_classified(rec.emp_code, v_temp_punch_time, TRUNC(v_temp_punch_time), 'MID', v_session_id);

CONTINUE;
END IF;

v_session_last_out := v_temp_punch_time;
v_session_out_count := 1;
v_session_punch_count := v_session_in_count + v_session_mid_count + v_session_out_count;
v_last_punch_time := v_temp_punch_time;

add_classified(rec.emp_code, v_temp_punch_time, TRUNC(v_temp_punch_time), 'OUT', v_session_id);

save_session;

v_session_state := 'COMPLETED';
v_session_first_in := NULL;

CONTINUE;
END IF;

-- ==================== SESSION COMPLETED ====================
IF v_session_state = 'COMPLETED' THEN

v_new_first_in_hour := safe_hour(v_temp_punch_time) + (safe_minute(v_temp_punch_time) / 60);
v_new_shift_local := get_best_shift(v_new_first_in_hour, v_is_admin);

IF NVL(v_best_shift_local.is_night, 'N') = 'Y'
AND TRUNC(v_temp_punch_time) > TRUNC(v_session_work_date)
AND v_temp_punch_time <= v_shift_end_date THEN

FOR k IN REVERSE 1 .. v_shift.COUNT LOOP
IF v_shift(k).emp_code = rec.emp_code
AND v_shift(k).session_id = v_session_id THEN
v_shift(k).last_out := v_temp_punch_time;
v_shift(k).out_count := NVL(v_shift(k).out_count, 0) + 1;
v_shift(k).punch_count := NVL(v_shift(k).punch_count, 0) + 1;
EXIT;
END IF;
END LOOP;

v_session_last_out := v_temp_punch_time;

add_classified(rec.emp_code, v_temp_punch_time, TRUNC(v_temp_punch_time), 'OUT', v_session_id);

CONTINUE;
END IF;

IF TRUNC(v_temp_punch_time) > TRUNC(v_session_work_date) THEN

IF TRUNC(v_temp_punch_time) > TRUNC(p_work_date) THEN
CONTINUE;
END IF;

v_session_id := v_session_id + 1;
v_session_state := 'OPEN';
v_session_first_in := v_temp_punch_time;
v_session_work_date := TRUNC(v_temp_punch_time);
v_session_in_count := 1;
v_session_out_count := 0;
v_session_mid_count := 0;
v_session_punch_count := 1;
v_session_last_out := NULL;
v_last_punch_time := v_temp_punch_time;

v_best_shift_local := v_new_shift_local;
calculate_session_limits(v_session_first_in);

add_classified(rec.emp_code, v_temp_punch_time, TRUNC(v_temp_punch_time), 'IN', v_session_id);

CONTINUE;
END IF;

IF TRUNC(v_temp_punch_time) = TRUNC(v_session_work_date) THEN
IF v_session_last_out IS NOT NULL
AND is_likely_new_session(v_temp_punch_time, v_session_last_out,
v_best_shift_local, v_shift_end_date) THEN

v_session_id := v_session_id + 1;
v_session_state := 'OPEN';
v_session_first_in := v_temp_punch_time;
v_session_work_date := TRUNC(v_temp_punch_time);
v_session_in_count := 1;
v_session_out_count := 0;
v_session_mid_count := 0;
v_session_punch_count := 1;
v_session_last_out := NULL;
v_last_punch_time := v_temp_punch_time;

v_best_shift_local := v_new_shift_local;
calculate_session_limits(v_session_first_in);

add_classified(rec.emp_code, v_temp_punch_time, TRUNC(v_temp_punch_time), 'IN', v_session_id);

CONTINUE;
END IF;
END IF;

add_classified(rec.emp_code, v_temp_punch_time, TRUNC(v_temp_punch_time), 'EXCEPTION', v_session_id);

log_engine_step('EXCEPTION_PUNCH',
'Punch after session completed | Time=' || TO_CHAR(v_temp_punch_time, 'HH24:MI:SS'),
TRUNC(v_temp_punch_time), rec.emp_code);

CONTINUE;
END IF;
END LOOP;

IF v_session_state = 'OPEN' AND v_session_first_in IS NOT NULL THEN
save_session;
END IF;

log_engine_step('RESOLVE_SHIFT_COMPLETE',
'Shifts resolved: ' || v_shift.COUNT || ' | MID: ' || v_mid_idx,
p_work_date);

EXCEPTION
WHEN OTHERS THEN
log_engine_step('RESOLVE_SHIFT_FATAL', 'Error: ' || SQLERRM, p_work_date);
RAISE;
END resolve_shift_for_emp;

-- ==================== INSERT MOVES ====================
PROCEDURE insert_moves IS
v_count NUMBER := 0;
v_emp_name VARCHAR2(200);
v_mid_times VARCHAR2(4000);
v_move_exists NUMBER;
BEGIN
FOR i IN 1 .. v_shift.COUNT LOOP
IF v_shift(i).mid_count > 1 THEN
v_mid_times := NULL;
FOR m IN 1 .. v_mid_idx LOOP
IF v_mid_collection(m).emp_code = v_shift(i).emp_code
AND v_mid_collection(m).session_id = v_shift(i).session_id THEN
IF v_mid_times IS NULL THEN
v_mid_times := TO_CHAR(v_mid_collection(m).punch_time, 'HH24:MI');
ELSE
v_mid_times := v_mid_times || ', ' || TO_CHAR(v_mid_collection(m).punch_time, 'HH24:MI');
END IF;
END IF;
END LOOP;

BEGIN
SELECT emp_name INTO v_emp_name
FROM emp_import
WHERE emp_code = v_shift(i).emp_code AND ROWNUM = 1;
EXCEPTION WHEN NO_DATA_FOUND THEN
v_emp_name := 'Unknown';
END;

SELECT COUNT(*) INTO v_move_exists
FROM att_moves
WHERE emp_code = v_shift(i).emp_code
AND work_date = v_shift(i).work_date
AND session_id = v_shift(i).session_id
AND shift_type = v_shift(i).shift_type
AND ROWNUM = 1;

IF v_move_exists = 0 THEN
INSERT INTO att_moves (
id, emp_code, emp_name, work_date, move_count,
session_id, shift_type, created_date, notes
) VALUES (
att_moves_seq.NEXTVAL,
v_shift(i).emp_code,
v_emp_name,
v_shift(i).work_date,
v_shift(i).mid_count,
v_shift(i).session_id,
v_shift(i).shift_type,
SYSDATE,
'MID at: ' || v_mid_times || ' (Total: ' || v_shift(i).mid_count || ' moves)'
);
v_count := v_count + 1;
ELSE
DBMS_OUTPUT.PUT_LINE('MOVE_ALREADY_EXISTS | Emp=' || v_shift(i).emp_code ||
' | Date=' || TO_CHAR(v_shift(i).work_date, 'DD-MM-YYYY') ||
' | Session=' || v_shift(i).session_id);
END IF;
END IF;
END LOOP;

COMMIT;
DBMS_OUTPUT.PUT_LINE('Inserted ' || v_count || ' new move records into att_moves');
EXCEPTION
WHEN OTHERS THEN
ROLLBACK;
DBMS_OUTPUT.PUT_LINE('Error inserting moves: ' || SQLERRM);
END insert_moves;

-- ==================== INSERT DAILY ATTENDANCE ====================
PROCEDURE insert_daily_attendance(p_work_date DATE) IS
v_temp_emp_code NUMBER;
v_temp_emp_name VARCHAR2(200);
v_temp_emp_dept VARCHAR2(100);
v_temp_shift_id NUMBER;
v_temp_shift_type VARCHAR2(50);
v_temp_is_night CHAR(1);

v_first_punch DATE := NULL;
v_last_punch DATE := NULL;
v_punch_count NUMBER := 0;
v_mid_count NUMBER := 0;
v_weekday VARCHAR2(20);

v_work_min NUMBER := 0;
v_overtime_min NUMBER := 0;
v_late_min NUMBER := 0;
v_early_out_min NUMBER := 0;
v_attend_status VARCHAR2(20) := 'ABSENT';
v_total_hours NUMBER(6,2) := 0;
v_early_in_min NUMBER := 0;
v_early_in_hour NUMBER := 0;
v_night_work_min NUMBER := 0;
v_night_work_hour NUMBER := 0;
v_notes VARCHAR2(4000);
v_shift_start_date DATE;
v_shift_end_date DATE;
v_actual_work_date DATE;

TYPE insert_rec IS RECORD (
daily_id       NUMBER,
emp_code       NUMBER,
emp_name       VARCHAR2(200),
dept           VARCHAR2(100),
work_date      DATE,
weekday        VARCHAR2(20),
shift_id       NUMBER,
shift_type     VARCHAR2(50),
first_in       DATE,
last_out       DATE,
work_min       NUMBER,
total_hours    NUMBER,
raw_count      NUMBER,
mid_count      NUMBER,
status         VARCHAR2(20),
ot_min         NUMBER,
late_min       NUMBER,
early_min      NUMBER,
ot_hours       NUMBER,
late_hours     NUMBER,
early_hours    NUMBER,
is_night       CHAR(1),
notes          VARCHAR2(4000),
early_in_min   NUMBER,
early_in_hour  NUMBER,
night_work_min NUMBER,
night_work_hour NUMBER
);
TYPE insert_tab IS TABLE OF insert_rec INDEX BY PLS_INTEGER;
v_insert insert_tab;

v_insert_idx NUMBER := 0;
v_seq_val NUMBER;
v_success_count NUMBER := 0;
v_error_count NUMBER := 0;

v_emp_punch_list VARCHAR2(2000);
v_mid_punch_times VARCHAR2(500);

TYPE processed_key_tab IS TABLE OF VARCHAR2(200) INDEX BY PLS_INTEGER;
v_processed_keys processed_key_tab;
v_processed_count NUMBER := 0;
v_current_key VARCHAR2(200);
v_is_duplicate BOOLEAN;
BEGIN
FOR i IN 1 .. v_shift.COUNT LOOP
IF v_shift(i).first_in IS NOT NULL THEN
v_current_key := v_shift(i).emp_code || '_' ||
TO_CHAR(v_shift(i).work_date, 'YYYYMMDD') || '_' ||
TO_CHAR(v_shift(i).first_in, 'HH24MISS');
ELSE
v_current_key := v_shift(i).emp_code || '_' ||
TO_CHAR(v_shift(i).work_date, 'YYYYMMDD') || '_NOIN';
END IF;

v_is_duplicate := FALSE;
FOR k IN 1 .. v_processed_count LOOP
IF v_processed_keys(k) = v_current_key THEN
v_is_duplicate := TRUE;
EXIT;
END IF;
END LOOP;

IF NOT v_is_duplicate AND v_shift(i).first_in IS NOT NULL THEN
FOR j IN 1 .. i-1 LOOP
IF v_shift(j).emp_code = v_shift(i).emp_code
AND v_shift(j).first_in = v_shift(i).first_in THEN
v_is_duplicate := TRUE;
EXIT;
END IF;
END LOOP;
END IF;

IF v_is_duplicate THEN
CONTINUE;
END IF;

v_processed_count := v_processed_count + 1;
v_processed_keys(v_processed_count) := v_current_key;

BEGIN
v_temp_emp_code := v_shift(i).emp_code;
v_temp_is_night := NVL(v_shift(i).is_night, 'N');
v_temp_shift_id := v_shift(i).shift_id;
v_temp_shift_type := v_shift(i).shift_type;
v_first_punch := v_shift(i).first_in;
v_last_punch := v_shift(i).last_out;
v_punch_count := v_shift(i).punch_count;
v_mid_count := NVL(v_shift(i).mid_count, 0);

-- ? ?? ?????? ????????
IF v_punch_count = 1 AND v_last_punch IS NULL THEN
v_temp_shift_id := 0;
v_temp_shift_type := 'UNASSIGNED';
v_temp_is_night := 'N';
END IF;

v_emp_punch_list := '';
v_mid_punch_times := '';

-- ? ?????: v_tab ???? ???? ?????
IF v_tab.COUNT > 0 THEN
FOR j IN 1 .. v_tab.COUNT LOOP
IF v_tab(j).emp_code = v_temp_emp_code
AND TRUNC(v_tab(j).punch_time) = TRUNC(p_work_date) THEN
IF v_tab(j).punch_time IS NOT NULL THEN
v_emp_punch_list := v_emp_punch_list || ' ' ||
TO_CHAR(v_tab(j).punch_time, 'HH24:MI') || '(' ||
TRIM(UPPER(v_tab(j).punch_status)) || ')';

IF TRIM(UPPER(v_tab(j).punch_status)) NOT IN ('IN', 'OUT') THEN
v_mid_punch_times := v_mid_punch_times || ' ' || TO_CHAR(v_tab(j).punch_time, 'HH24:MI');
END IF;
END IF;
END IF;
END LOOP;
END IF;

IF v_emp_punch_list IS NULL OR v_emp_punch_list = '' THEN
v_emp_punch_list := 'N/A';
END IF;

v_weekday := NULL;
v_temp_emp_name := 'Unknown';
v_temp_emp_dept := 'Unknown';

BEGIN
SELECT emp_name, dept_name INTO v_temp_emp_name, v_temp_emp_dept
FROM emp_import
WHERE emp_code = v_temp_emp_code AND ROWNUM = 1;
EXCEPTION
WHEN OTHERS THEN NULL;
END;
DECLARE
    v_first_in_hour NUMBER := TO_NUMBER(TO_CHAR(v_first_punch, 'HH24'))
                              + (TO_NUMBER(TO_CHAR(v_first_punch, 'MI')) / 60);
BEGIN
    -- ?? ??????? ????? ? first_in ??? shift_start ? ??????? ???? ???
    IF v_temp_is_night = 'Y'
       AND v_first_in_hour < v_shift(i).start_time
    THEN
        v_actual_work_date := TRUNC(v_first_punch) - 1;
    ELSE
        v_actual_work_date := TRUNC(v_first_punch);
    END IF;
END;
IF v_weekday IS NULL THEN
SELECT TO_CHAR(v_actual_work_date, 'DY', 'NLS_DATE_LANGUAGE=ARABIC') INTO v_weekday FROM DUAL;
END IF;

v_shift_start_date := TRUNC(v_actual_work_date) + (FLOOR(v_shift(i).start_time) / 24) +
(ROUND((v_shift(i).start_time - FLOOR(v_shift(i).start_time)) * 60) / 1440);

IF v_temp_is_night = 'Y' AND v_shift(i).end_time < v_shift(i).start_time THEN
v_shift_end_date := TRUNC(v_actual_work_date) + 1 + (FLOOR(v_shift(i).end_time) / 24) +
(ROUND((v_shift(i).end_time - FLOOR(v_shift(i).end_time)) * 60) / 1440);
ELSE
v_shift_end_date := TRUNC(v_actual_work_date) + (FLOOR(v_shift(i).end_time) / 24) +
(ROUND((v_shift(i).end_time - FLOOR(v_shift(i).end_time)) * 60) / 1440);
END IF;

IF v_punch_count >= 2 AND v_first_punch IS NOT NULL AND v_last_punch IS NOT NULL THEN
v_work_min := (v_last_punch - v_first_punch) * 24 * 60;
IF v_temp_is_night = 'Y' AND v_last_punch < v_first_punch THEN
v_work_min := ((v_last_punch + 1) - v_first_punch) * 24 * 60;
END IF;
v_work_min := ROUND(GREATEST(v_work_min, 0));

v_late_min := calculate_late_minutes(v_shift_start_date, v_first_punch, v_temp_shift_id);
v_early_out_min := calculate_early_out(v_shift_end_date, v_last_punch, v_temp_shift_id, v_temp_is_night);
v_overtime_min := calculate_overtime(v_first_punch, v_last_punch, v_shift_start_date, v_shift_end_date, v_temp_is_night, v_temp_shift_id);
v_total_hours := ROUND(v_work_min / 60, 2);
v_attend_status := determine_attend_status(v_work_min, v_late_min, v_first_punch, v_last_punch, v_temp_emp_code);
v_early_in_min := early_in_min(v_shift_start_date, v_first_punch, v_temp_shift_id);
v_early_in_hour := early_in_hours(v_shift_start_date, v_first_punch, v_temp_shift_id);
v_overtime_min := v_overtime_min + v_early_in_min;

v_night_work_min := calculate_night_shift_hours(
v_first_punch, v_last_punch,
v_shift_start_date, v_shift_end_date
);
v_night_work_hour := ROUND(v_night_work_min / 60, 2);
ELSE
v_work_min := 0;
v_overtime_min := 0;
v_late_min := 0;
v_early_out_min := 0;
v_total_hours := 0;
v_early_in_min := 0;
v_early_in_hour := 0;
v_night_work_min := 0;
v_night_work_hour := 0;
v_attend_status := CASE WHEN v_punch_count = 0 THEN 'ABSENT' ELSE 'INCOMPLETE' END;
END IF;

IF v_first_punch IS NOT NULL AND v_last_punch IS NOT NULL THEN
v_notes := 'Punches: ' || v_punch_count || ' (IN: 1, OUT: 1, MID: ' || v_mid_count || ')' ||
' | Times: ' || TRIM(v_emp_punch_list) ||
' | Shift: ' || v_temp_shift_type || ' (' || v_shift(i).start_time || '-' || v_shift(i).end_time || ')' ||
CASE WHEN v_temp_is_night = 'Y' THEN ' Night' ELSE '' END ||
' | First: ' || NVL(TO_CHAR(v_first_punch, 'HH24:MI'), 'N/A') ||
' | Last: ' || NVL(TO_CHAR(v_last_punch, 'HH24:MI'), 'N/A');
ELSIF v_first_punch IS NOT NULL THEN
IF v_punch_count = 1 AND v_last_punch IS NULL THEN
v_notes := 'Single punch (IN only) | Time: ' ||
TO_CHAR(v_first_punch, 'HH24:MI') ||
' | Shift: NOT ASSIGNED';
ELSE
v_notes := 'Punches: 1 (IN: 1, OUT: 0, MID: 0) | Times: ' || TRIM(v_emp_punch_list) ||
' | Shift: ' || v_temp_shift_type || ' (' || v_shift(i).start_time || '-' || v_shift(i).end_time || ')' ||
CASE WHEN v_temp_is_night = 'Y' THEN ' Night' ELSE '' END ||
' | First: ' || NVL(TO_CHAR(v_first_punch, 'HH24:MI'), 'N/A') ||
' | Last: N/A';
END IF;
ELSE
v_notes := 'No punches recorded';
END IF;

IF LENGTH(v_notes) > 4000 THEN v_notes := SUBSTR(v_notes, 1, 3970) || '...'; END IF;

SELECT emp_daily_seq.NEXTVAL INTO v_seq_val FROM DUAL;

v_insert_idx := v_insert_idx + 1;
v_insert(v_insert_idx).daily_id := v_seq_val;
v_insert(v_insert_idx).emp_code := v_temp_emp_code;
v_insert(v_insert_idx).emp_name := v_temp_emp_name;
v_insert(v_insert_idx).dept := v_temp_emp_dept;
v_insert(v_insert_idx).work_date := v_actual_work_date;
v_insert(v_insert_idx).weekday := v_weekday;
v_insert(v_insert_idx).shift_id := v_temp_shift_id;
v_insert(v_insert_idx).shift_type := v_temp_shift_type;
v_insert(v_insert_idx).first_in := v_first_punch;
v_insert(v_insert_idx).last_out := v_last_punch;
v_insert(v_insert_idx).work_min := ROUND(v_work_min);
v_insert(v_insert_idx).total_hours := v_total_hours;
v_insert(v_insert_idx).raw_count := v_punch_count;
v_insert(v_insert_idx).mid_count := v_mid_count;
v_insert(v_insert_idx).status := v_attend_status;
v_insert(v_insert_idx).ot_min := ROUND(v_overtime_min);
v_insert(v_insert_idx).late_min := ROUND(v_late_min);
v_insert(v_insert_idx).early_min := ROUND(v_early_out_min);
v_insert(v_insert_idx).ot_hours := ROUND(v_overtime_min / 60, 2);
v_insert(v_insert_idx).late_hours := ROUND(v_late_min / 60, 2);
v_insert(v_insert_idx).early_hours := ROUND(v_early_out_min / 60, 2);
v_insert(v_insert_idx).is_night := v_temp_is_night;
v_insert(v_insert_idx).notes := SUBSTR(v_notes, 1, 4000);
v_insert(v_insert_idx).early_in_min := v_early_in_min;
v_insert(v_insert_idx).early_in_hour := v_early_in_hour;
v_insert(v_insert_idx).night_work_min := v_night_work_min;
v_insert(v_insert_idx).night_work_hour := v_night_work_hour;

EXCEPTION
WHEN OTHERS THEN
v_error_count := v_error_count + 1;
log_engine_step('INSERT_DAILY_ROW_ERROR',
'Emp=' || v_temp_emp_code || ' | ' || SQLERRM,
p_work_date, v_temp_emp_code);
END;
END LOOP;

-- ============================================================
-- MERGE ?? Reconciliation
-- ============================================================
IF v_insert.COUNT > 0 THEN
FOR j IN 1 .. v_insert.COUNT LOOP
DECLARE
v_old_daily_id          NUMBER;
v_old_first_in          DATE;
v_old_last_out          DATE;
v_old_shift_id          NUMBER;
v_old_shift_type        VARCHAR2(50);
v_old_is_night          CHAR(1);

v_final_first_in        DATE;
v_final_last_out        DATE;

v_old_shift_end_date    DATE;
v_old_ot_end_date       DATE;

v_first_in_changed      BOOLEAN := FALSE;
v_last_out_changed      BOOLEAN := FALSE;

v_existing_record       BOOLEAN := FALSE;
v_existing_complete     BOOLEAN := FALSE;

v_recalc_start_hour     NUMBER;
v_recalc_end_hour       NUMBER;
v_recalc_is_night       CHAR(1);
v_recalc_shift_start    DATE;
v_recalc_shift_end      DATE;
v_new_work_min          NUMBER := 0;
v_new_late_min          NUMBER := 0;
v_new_early_min         NUMBER := 0;
v_new_ot_min            NUMBER := 0;
v_new_status            VARCHAR2(20);
v_new_night_work_min    NUMBER := 0;
v_new_night_work_hour   NUMBER := 0;

v_shift_start_time      DATE;
v_shift_end_time        DATE;
v_shift_is_night        CHAR(1);

v_cand_emp_code         NUMBER;
v_cand_first_in         DATE;
v_cand_last_out         DATE;
v_cand_work_date        DATE;
v_cand_emp_name         VARCHAR2(200);
v_cand_dept             VARCHAR2(100);
v_cand_weekday          VARCHAR2(20);
v_cand_shift_id         NUMBER;
v_cand_shift_type       VARCHAR2(50);
v_cand_is_night         CHAR(1);
v_cand_raw_count        NUMBER;
v_cand_mid_count        NUMBER;
v_cand_notes            VARCHAR2(4000);
v_cand_early_in_min     NUMBER;
v_cand_early_in_hour    NUMBER;
v_cand_night_work_min   NUMBER;
v_cand_night_work_hour  NUMBER;

v_inc_final_first_in    DATE;
v_inc_final_last_out    DATE;

v_insert_daily_id       NUMBER;
v_insert_work_min       NUMBER;
v_insert_total_hours    NUMBER;
v_insert_status         VARCHAR2(20);
v_insert_ot_min         NUMBER;
v_insert_late_min       NUMBER;
v_insert_early_min      NUMBER;
v_insert_ot_hours       NUMBER;
v_insert_late_hours     NUMBER;
v_insert_early_hours    NUMBER;

v_new_notes             VARCHAR2(4000);
BEGIN
v_cand_emp_code      := v_insert(j).emp_code;
v_cand_first_in      := v_insert(j).first_in;
v_cand_last_out      := v_insert(j).last_out;
v_cand_work_date     := v_insert(j).work_date;
v_cand_emp_name      := v_insert(j).emp_name;
v_cand_dept          := v_insert(j).dept;
v_cand_weekday       := v_insert(j).weekday;
v_cand_shift_id      := v_insert(j).shift_id;
v_cand_shift_type    := v_insert(j).shift_type;
v_cand_is_night      := v_insert(j).is_night;
v_cand_raw_count     := v_insert(j).raw_count;
v_cand_mid_count     := v_insert(j).mid_count;
v_cand_notes         := v_insert(j).notes;
v_cand_early_in_min  := v_insert(j).early_in_min;
v_cand_early_in_hour := v_insert(j).early_in_hour;
v_cand_night_work_min  := v_insert(j).night_work_min;
v_cand_night_work_hour := v_insert(j).night_work_hour;

v_insert_daily_id    := v_insert(j).daily_id;
v_insert_work_min    := v_insert(j).work_min;
v_insert_total_hours := v_insert(j).total_hours;
v_insert_status      := v_insert(j).status;
v_insert_ot_min      := v_insert(j).ot_min;
v_insert_late_min    := v_insert(j).late_min;
v_insert_early_min   := v_insert(j).early_min;
v_insert_ot_hours    := v_insert(j).ot_hours;
v_insert_late_hours  := v_insert(j).late_hours;
v_insert_early_hours := v_insert(j).early_hours;

-- 1. ??? ????? ???????
BEGIN
SELECT
daily_id, first_in, last_out, shift_id, shift_type, is_night
INTO
v_old_daily_id, v_old_first_in, v_old_last_out,
v_old_shift_id, v_old_shift_type, v_old_is_night
FROM emp_attend_daily
WHERE emp_code = v_cand_emp_code
AND TRUNC(work_date) = TRUNC(v_cand_work_date)
AND ROWNUM = 1;

v_existing_record := TRUE;
EXCEPTION
WHEN NO_DATA_FOUND THEN
v_existing_record   := FALSE;
v_existing_complete := FALSE;
v_old_daily_id      := NULL;
v_old_first_in      := NULL;
v_old_last_out      := NULL;
v_old_shift_id      := NULL;
v_old_shift_type    := NULL;
v_old_is_night      := NULL;
END;

-- 2. ?? ???? ??? ???? ? INSERT
IF NOT v_existing_record THEN
INSERT INTO emp_attend_daily (
daily_id, emp_code, emp_name, department,
work_date, weekday, shift_id, shift_type,
first_in, last_out, work_min, total_hours,
raw_punch_count, attend_status, overtime_min, late_min, early_out_min,
overtime_hours, late_hours, early_out_hours,
is_night, notes, process_flag, source, created_at, created_by,
early_in_min, early_in_hour,
night_work_min, night_work_hour
)
VALUES (
v_insert_daily_id, v_cand_emp_code, v_cand_emp_name, v_cand_dept,
v_cand_work_date, v_cand_weekday, v_cand_shift_id, v_cand_shift_type,
v_cand_first_in, v_cand_last_out, v_insert_work_min, v_insert_total_hours,
v_cand_raw_count, v_insert_status, v_insert_ot_min,
v_insert_late_min, v_insert_early_min,
v_insert_ot_hours, v_insert_late_hours, v_insert_early_hours,
v_cand_is_night, v_cand_notes,
'N', 'PUNCH_BASED', SYSDATE, 'ATTEND_ENG_PKG',
v_cand_early_in_min, v_cand_early_in_hour,
v_cand_night_work_min, v_cand_night_work_hour
);
DBMS_OUTPUT.PUT_LINE(
'NEW_RECORD_INSERTED'
|| ' | Emp=' || v_cand_emp_code
|| ' | Daily_ID=' || v_insert_daily_id
|| ' | FIRST_IN=' || TO_CHAR(v_cand_first_in, 'HH24:MI:SS')
|| ' | LAST_OUT=' || TO_CHAR(NVL(v_cand_last_out, v_cand_first_in), 'HH24:MI:SS')
);

-- 3. ???? ??? ????
ELSE
IF v_old_first_in IS NOT NULL
AND v_old_last_out IS NOT NULL
THEN
v_existing_complete := TRUE;
ELSE
v_existing_complete := FALSE;
END IF;

-- 4. ????? ??????? ?????
IF v_existing_complete THEN
v_final_first_in := v_old_first_in;
v_final_last_out := v_old_last_out;

-- 4A. FIRST_IN ?? v_cand ???? ????? ???????
IF v_cand_first_in IS NOT NULL
AND (v_old_first_in IS NULL OR v_cand_first_in != v_old_first_in)
AND ABS((v_cand_first_in - v_old_first_in) * 24) <= 1
THEN
v_final_first_in    := v_cand_first_in;
v_first_in_changed  := TRUE;
DBMS_OUTPUT.PUT_LINE('FIRST_IN_FROM_RESOLVE | Emp=' || v_cand_emp_code);
ELSE
IF v_cand_first_in IS NOT NULL AND v_cand_first_in != v_old_first_in THEN
log_engine_step('SEPARATE_SESSION_DETECTED',
'Emp=' || v_cand_emp_code ||
' | Old=' || TO_CHAR(v_old_first_in,'HH24:MI') ||
' | New=' || TO_CHAR(v_cand_first_in,'HH24:MI'),
v_cand_work_date, v_cand_emp_code);
END IF;
END IF;

-- 4B. Reconcile LAST_OUT
IF v_cand_last_out IS NOT NULL
AND v_old_last_out IS NOT NULL
AND v_cand_last_out > v_old_last_out
THEN
BEGIN
SELECT start_time, end_time, is_night
INTO v_shift_start_time, v_shift_end_time, v_shift_is_night
FROM att_emp_shift
WHERE shift_id = v_old_shift_id;

v_old_shift_end_date :=
TRUNC(v_old_first_in)
+ (TO_NUMBER(TO_CHAR(v_shift_end_time, 'HH24')) / 24)
+ (TO_NUMBER(TO_CHAR(v_shift_end_time, 'MI')) / 1440);

IF v_shift_is_night = 'Y'
AND TO_NUMBER(TO_CHAR(v_shift_end_time, 'HH24')) < TO_NUMBER(TO_CHAR(v_shift_start_time, 'HH24'))
THEN
v_old_shift_end_date := v_old_shift_end_date + 1;
END IF;

v_old_ot_end_date := v_old_shift_end_date + (6/24);

IF v_cand_last_out <= v_old_ot_end_date THEN
v_final_last_out   := v_cand_last_out;
v_last_out_changed := TRUE;

DBMS_OUTPUT.PUT_LINE(
'LAST_OUT_EXTENDED'
|| ' | Emp=' || v_cand_emp_code
|| ' | Old=' || TO_CHAR(v_old_last_out, 'HH24:MI:SS')
|| ' | New=' || TO_CHAR(v_cand_last_out, 'HH24:MI:SS')
);
ELSE
log_engine_step(
'LAST_OUT_REJECTED',
'Emp=' || v_cand_emp_code ||
' | Candidate=' || TO_CHAR(v_cand_last_out, 'HH24:MI:SS') ||
' | OT_END=' || TO_CHAR(v_old_ot_end_date, 'HH24:MI:SS'),
TRUNC(v_cand_work_date),
v_cand_emp_code
);
END IF;
EXCEPTION
WHEN NO_DATA_FOUND THEN
NULL;
END;
END IF;

-- 4C. ????? ???? ????????
IF v_first_in_changed OR v_last_out_changed THEN
BEGIN
SELECT
TO_NUMBER(TO_CHAR(start_time, 'HH24')) + (TO_NUMBER(TO_CHAR(start_time, 'MI')) / 60),
TO_NUMBER(TO_CHAR(end_time, 'HH24')) + (TO_NUMBER(TO_CHAR(end_time, 'MI')) / 60),
is_night
INTO
v_recalc_start_hour, v_recalc_end_hour, v_recalc_is_night
FROM att_emp_shift
WHERE shift_id = v_old_shift_id;

v_recalc_shift_start := TRUNC(v_final_first_in) + (v_recalc_start_hour / 24);

IF v_recalc_is_night = 'Y' AND v_recalc_end_hour < v_recalc_start_hour THEN
v_recalc_shift_end := TRUNC(v_final_first_in) + 1 + (v_recalc_end_hour / 24);
ELSE
v_recalc_shift_end := TRUNC(v_final_first_in) + (v_recalc_end_hour / 24);
END IF;

IF v_final_first_in IS NOT NULL AND v_final_last_out IS NOT NULL THEN
IF v_final_last_out >= v_final_first_in THEN
v_new_work_min := ROUND((v_final_last_out - v_final_first_in) * 24 * 60);
ELSIF v_recalc_is_night = 'Y' THEN
v_new_work_min := ROUND(((v_final_last_out + 1) - v_final_first_in) * 24 * 60);
END IF;
END IF;

v_new_late_min := calculate_late_minutes(v_recalc_shift_start, v_final_first_in, v_old_shift_id);
v_new_early_min := calculate_early_out(v_recalc_shift_end, v_final_last_out, v_old_shift_id, v_recalc_is_night);
v_new_ot_min := calculate_overtime(v_final_first_in, v_final_last_out, v_recalc_shift_start, v_recalc_shift_end, v_recalc_is_night, v_old_shift_id);
v_new_status := determine_attend_status(v_new_work_min, v_new_late_min, v_final_first_in, v_final_last_out, v_cand_emp_code);

v_new_night_work_min := calculate_night_shift_hours(
v_final_first_in, v_final_last_out,
v_recalc_shift_start, v_recalc_shift_end
);
v_new_night_work_hour := ROUND(v_new_night_work_min / 60, 2);

v_new_notes := v_cand_notes || ' | RECONCILED';
IF v_first_in_changed THEN v_new_notes := v_new_notes || ' | FIRST_IN adjusted'; END IF;
IF v_last_out_changed THEN v_new_notes := v_new_notes || ' | LAST_OUT extended'; END IF;

UPDATE emp_attend_daily d
SET
d.emp_name          = v_cand_emp_name,
d.department        = v_cand_dept,
d.weekday           = v_cand_weekday,
d.first_in          = v_final_first_in,
d.last_out          = v_final_last_out,
d.work_min          = v_new_work_min,
d.total_hours       = ROUND(v_new_work_min / 60, 2),
d.attend_status     = v_new_status,
d.overtime_min      = v_new_ot_min,
d.late_min          = v_new_late_min,
d.early_out_min     = v_new_early_min,
d.overtime_hours    = ROUND(v_new_ot_min / 60, 2),
d.late_hours        = ROUND(v_new_late_min / 60, 2),
d.early_out_hours   = ROUND(v_new_early_min / 60, 2),
d.night_work_min    = v_new_night_work_min,
d.night_work_hour   = v_new_night_work_hour,
d.updated_at        = SYSDATE,
d.updated_by        = 'ATTEND_ENG_PKG',
d.process_flag      = 'N',
d.source            = 'PUNCH_BASED',
d.notes             = v_new_notes
WHERE d.daily_id = v_old_daily_id;
END;
END IF;

-- 4D. ??? ????? ??? ?? ???? ?????
IF NOT v_first_in_changed AND NOT v_last_out_changed THEN
DBMS_OUTPUT.PUT_LINE(
'COMPLETE_RECORD_PRESERVED'
|| ' | Emp=' || v_cand_emp_code
|| ' | Daily_ID=' || v_old_daily_id
);
END IF;

-- 5. ????? ??????? ??? ?????
ELSE
-- ? 5-0. ?? ????? ?????? shift_id = 0
IF v_old_shift_id = 0 AND v_cand_shift_id != 0 THEN
DBMS_OUTPUT.PUT_LINE(
'SHIFT_REASSIGNED_FROM_ZERO'
|| ' | Emp=' || v_cand_emp_code
|| ' | Old_Shift=0'
|| ' | New_Shift=' || v_cand_shift_id
|| ' | Type=' || v_cand_shift_type
);

log_engine_step('SHIFT_REASSIGNED_FROM_ZERO',
'Emp=' || v_cand_emp_code ||
' | Old_Shift=0 | New_Shift=' || v_cand_shift_id ||
' | Type=' || v_cand_shift_type,
v_cand_work_date, v_cand_emp_code);
END IF;

-- 5A. FIRST_IN
IF v_cand_first_in IS NOT NULL THEN
v_inc_final_first_in := v_cand_first_in;

DBMS_OUTPUT.PUT_LINE(
'INCOMPLETE_FIRST_IN_FROM_RESOLVE'
|| ' | Emp=' || v_cand_emp_code
|| ' | Old=' || NVL(TO_CHAR(v_old_first_in, 'HH24:MI:SS'), 'NULL')
|| ' | New=' || TO_CHAR(v_cand_first_in, 'HH24:MI:SS')
);
ELSE
v_inc_final_first_in := v_old_first_in;
END IF;

-- 5B. LAST_OUT
v_inc_final_last_out := v_old_last_out;

IF v_old_last_out IS NULL THEN
v_inc_final_last_out := v_cand_last_out;
ELSIF v_cand_last_out IS NOT NULL
AND v_cand_last_out > v_old_last_out
THEN
BEGIN
SELECT start_time, end_time, is_night
INTO v_shift_start_time, v_shift_end_time, v_shift_is_night
FROM att_emp_shift
WHERE shift_id = v_old_shift_id;

v_old_shift_end_date :=
TRUNC(v_old_first_in)
+ (TO_NUMBER(TO_CHAR(v_shift_end_time, 'HH24')) / 24)
+ (TO_NUMBER(TO_CHAR(v_shift_end_time, 'MI')) / 1440);

IF v_shift_is_night = 'Y'
AND TO_NUMBER(TO_CHAR(v_shift_end_time, 'HH24')) < TO_NUMBER(TO_CHAR(v_shift_start_time, 'HH24'))
THEN
v_old_shift_end_date := v_old_shift_end_date + 1;
END IF;

v_old_ot_end_date := v_old_shift_end_date + (6 / 24);

IF v_cand_last_out <= v_old_ot_end_date THEN
v_inc_final_last_out := v_cand_last_out;
END IF;
EXCEPTION
WHEN NO_DATA_FOUND THEN
NULL;
END;
END IF;

-- 5C. ????? ???? ????????
IF v_inc_final_first_in IS NOT NULL
AND v_inc_final_last_out IS NOT NULL
THEN
BEGIN
SELECT
TO_NUMBER(TO_CHAR(start_time, 'HH24')) + (TO_NUMBER(TO_CHAR(start_time, 'MI')) / 60),
TO_NUMBER(TO_CHAR(end_time, 'HH24')) + (TO_NUMBER(TO_CHAR(end_time, 'MI')) / 60),
is_night
INTO
v_recalc_start_hour, v_recalc_end_hour, v_recalc_is_night
FROM att_emp_shift
WHERE shift_id = v_cand_shift_id;

v_recalc_shift_start := TRUNC(v_inc_final_first_in) + (v_recalc_start_hour / 24);

IF v_recalc_is_night = 'Y' AND v_recalc_end_hour < v_recalc_start_hour THEN
v_recalc_shift_end := TRUNC(v_inc_final_first_in) + 1 + (v_recalc_end_hour / 24);
ELSE
v_recalc_shift_end := TRUNC(v_inc_final_first_in) + (v_recalc_end_hour / 24);
END IF;

IF v_recalc_is_night = 'Y'
AND v_inc_final_last_out < v_inc_final_first_in
THEN
v_new_work_min := ROUND(((v_inc_final_last_out + 1) - v_inc_final_first_in) * 24 * 60);
ELSE
v_new_work_min := ROUND((v_inc_final_last_out - v_inc_final_first_in) * 24 * 60);
END IF;

v_new_work_min := GREATEST(v_new_work_min, 0);

v_new_late_min := calculate_late_minutes(v_recalc_shift_start, v_inc_final_first_in, v_cand_shift_id);
v_new_early_min := calculate_early_out(v_recalc_shift_end, v_inc_final_last_out, v_cand_shift_id, v_recalc_is_night);
v_new_ot_min := calculate_overtime(v_inc_final_first_in, v_inc_final_last_out, v_recalc_shift_start, v_recalc_shift_end, v_recalc_is_night, v_cand_shift_id);
v_new_status := determine_attend_status(v_new_work_min, v_new_late_min, v_inc_final_first_in, v_inc_final_last_out, v_cand_emp_code);

v_new_night_work_min := calculate_night_shift_hours(
v_inc_final_first_in, v_inc_final_last_out,
v_recalc_shift_start, v_recalc_shift_end
);
v_new_night_work_hour := ROUND(v_new_night_work_min / 60, 2);
END;
ELSE
v_new_work_min   := 0;
v_new_late_min   := 0;
v_new_early_min  := 0;
v_new_ot_min     := 0;
v_new_status     := 'INCOMPLETE';
v_new_night_work_min := 0;
v_new_night_work_hour := 0;
END IF;

-- 5D. UPDATE
UPDATE emp_attend_daily d
SET
d.emp_name          = v_cand_emp_name,
d.department        = v_cand_dept,
d.weekday           = v_cand_weekday,
d.shift_id          = v_cand_shift_id,
d.shift_type        = v_cand_shift_type,
d.first_in          = v_inc_final_first_in,
d.last_out          = v_inc_final_last_out,
d.work_min          = v_new_work_min,
d.total_hours       = ROUND(v_new_work_min / 60, 2),
d.raw_punch_count   = v_cand_raw_count,
d.attend_status     = v_new_status,
d.overtime_min      = v_new_ot_min,
d.late_min          = v_new_late_min,
d.early_out_min     = v_new_early_min,
d.overtime_hours    = ROUND(v_new_ot_min / 60, 2),
d.late_hours        = ROUND(v_new_late_min / 60, 2),
d.early_out_hours   = ROUND(v_new_early_min / 60, 2),
d.night_work_min    = v_new_night_work_min,
d.night_work_hour   = v_new_night_work_hour,
d.is_night          = v_cand_is_night,
d.notes             = v_cand_notes,
d.process_flag      = 'N',
d.source            = 'PUNCH_BASED',
d.updated_at        = SYSDATE,
d.updated_by        = 'ATTEND_ENG_PKG',
d.early_in_min      = v_cand_early_in_min,
d.early_in_hour     = v_cand_early_in_hour
WHERE d.daily_id = v_old_daily_id;

DBMS_OUTPUT.PUT_LINE(
'INCOMPLETE_RECORD_RECONCILED'
|| ' | Emp=' || v_cand_emp_code
|| ' | Daily_ID=' || v_old_daily_id
);

END IF;

END IF;

END;
END LOOP;

v_success_count := v_success_count + v_insert.COUNT;

END IF;

COMMIT;
log_engine_step('INSERT_DAILY_COMPLETE',
'Processed: ' || v_success_count || ' employees, Errors: ' || v_error_count, p_work_date);

EXCEPTION
WHEN OTHERS THEN
log_engine_step('INSERT_DAILY_FATAL', SQLERRM, p_work_date);
RAISE;
END insert_daily_attendance;

-- ==================== LAST OUT ENGINE ====================
PROCEDURE last_out_engine IS
v_updated_count NUMBER := 0;
v_error_count NUMBER := 0;
BEGIN
log_engine_step('LAST_OUT_START', 'Processing last out punches', g_work_date);
FOR i IN 1 .. v_tab.COUNT LOOP
IF v_tab(i).punch_status = 'OUT'
AND v_tab(i).emp_code IS NOT NULL
AND v_tab(i).punch_time IS NOT NULL THEN
BEGIN
UPDATE emp_attend_daily d
SET d.last_out = v_tab(i).punch_time,
d.updated_at = SYSDATE,
d.updated_by = 'ATTEND_ENG_PKG'
WHERE d.emp_code = v_tab(i).emp_code
AND TRUNC(d.work_date) = TRUNC(v_tab(i).work_date)
AND (d.last_out IS NULL OR d.last_out < v_tab(i).punch_time)
AND v_tab(i).punch_time >= NVL(d.first_in, v_tab(i).punch_time);

IF SQL%ROWCOUNT > 0 THEN
v_updated_count := v_updated_count + 1;
END IF;
EXCEPTION
WHEN OTHERS THEN
v_error_count := v_error_count + 1;
END;
END IF;
END LOOP;
COMMIT;
log_engine_step('LAST_OUT_COMPLETE',
'Updated: ' || v_updated_count || ' | Errors: ' || v_error_count, g_work_date);
END last_out_engine;

-- ==================== UPDATE WORK MINUTES ====================
PROCEDURE update_work_minutes(p_work_date DATE) IS
v_updated_count NUMBER := 0;
v_start_hour NUMBER;
v_end_hour NUMBER;
v_work_min NUMBER;
BEGIN
FOR rec IN (SELECT d.daily_id, d.first_in, d.last_out,
s.start_time, s.end_time, s.is_night
FROM emp_attend_daily d
INNER JOIN att_emp_shift s ON d.shift_id = s.shift_id
WHERE d.work_date = p_work_date
AND d.first_in IS NOT NULL
AND d.last_out IS NOT NULL) LOOP
v_start_hour := TO_NUMBER(TO_CHAR(rec.start_time, 'HH24')) +
(TO_NUMBER(TO_CHAR(rec.start_time, 'MI')) / 60);
v_end_hour := TO_NUMBER(TO_CHAR(rec.end_time, 'HH24')) +
(TO_NUMBER(TO_CHAR(rec.end_time, 'MI')) / 60);

v_work_min := calc_work_min_hours(
v_start_hour, v_end_hour,
rec.first_in, rec.last_out,
p_work_date, rec.is_night
);

UPDATE emp_attend_daily d
SET work_min = ROUND(v_work_min),
total_hours = ROUND(v_work_min / 60, 2)
WHERE daily_id = rec.daily_id;

v_updated_count := v_updated_count + 1;
END LOOP;

COMMIT;
log_engine_step('UPDATE_WORK_COMPLETE', 'Updated: ' || v_updated_count, p_work_date);
END update_work_minutes;

-- ==================== CALCULATE ADDITIONAL METRICS ====================
PROCEDURE calculate_additional_metrics(p_work_date DATE) IS
v_updated_count NUMBER := 0;
BEGIN
FOR rec IN (SELECT d.daily_id, d.first_in, d.last_out, d.work_min,
s.start_time, s.end_time, s.is_night, s.shift_id
FROM emp_attend_daily d
INNER JOIN att_emp_shift s ON d.shift_id = s.shift_id
WHERE d.work_date = p_work_date
AND d.first_in IS NOT NULL
AND d.last_out IS NOT NULL) LOOP
DECLARE
v_start_hour NUMBER := TO_NUMBER(TO_CHAR(rec.start_time, 'HH24')) +
(TO_NUMBER(TO_CHAR(rec.start_time, 'MI')) / 60);
v_end_hour NUMBER := TO_NUMBER(TO_CHAR(rec.end_time, 'HH24')) +
(TO_NUMBER(TO_CHAR(rec.end_time, 'MI')) / 60);
v_shift_start DATE := TRUNC(rec.first_in) + (FLOOR(v_start_hour) / 24)
                     + (ROUND((v_start_hour - FLOOR(v_start_hour)) * 60) / 1440);v_shift_end DATE;
v_late_min NUMBER;
v_early_out_min NUMBER;
v_overtime_min NUMBER;
v_attend_status VARCHAR2(20);
v_night_work_min NUMBER;
v_night_work_hour NUMBER;
BEGIN
IF rec.is_night = 'Y' AND v_end_hour < v_start_hour THEN
    v_shift_end := TRUNC(rec.first_in) + 1 + (FLOOR(v_end_hour) / 24)
                   + (ROUND((v_end_hour - FLOOR(v_end_hour)) * 60) / 1440);
ELSE
    v_shift_end := TRUNC(rec.first_in) + (FLOOR(v_end_hour) / 24)
                   + (ROUND((v_end_hour - FLOOR(v_end_hour)) * 60) / 1440);
END IF;

v_late_min := calculate_late_minutes(v_shift_start, rec.first_in, rec.shift_id);
v_early_out_min := calculate_early_out(v_shift_end, rec.last_out, rec.shift_id, rec.is_night);
v_overtime_min := calculate_overtime(rec.first_in, rec.last_out, v_shift_start, v_shift_end, rec.is_night, rec.shift_id);
v_attend_status := determine_attend_status(rec.work_min, v_late_min, rec.first_in, rec.last_out);

v_night_work_min := calculate_night_shift_hours(
rec.first_in, rec.last_out,
v_shift_start, v_shift_end
);
v_night_work_hour := ROUND(v_night_work_min / 60, 2);

UPDATE emp_attend_daily d
SET overtime_min = ROUND(v_overtime_min),
late_min = ROUND(v_late_min),
early_out_min = ROUND(v_early_out_min),
overtime_hours = ROUND(v_overtime_min / 60, 2),
late_hours = ROUND(v_late_min / 60, 2),
early_out_hours = ROUND(v_early_out_min / 60, 2),
night_work_min = v_night_work_min,
night_work_hour = v_night_work_hour,
attend_status = v_attend_status
WHERE daily_id = rec.daily_id;

v_updated_count := v_updated_count + 1;
END;
END LOOP;

COMMIT;
log_engine_step('CALC_METRICS_COMPLETE', 'Updated: ' || v_updated_count, p_work_date);
END calculate_additional_metrics;

-- ==================== UPDATE PROCESSED FLAGS ====================
PROCEDURE update_processed_flags(p_work_date DATE) IS
BEGIN
UPDATE emp_attend_daily d
SET process_flag = 'P',
updated_at = SYSDATE,
updated_by = 'ATTEND_ENG_PKG'
WHERE work_date = p_work_date
AND process_flag = 'N'
AND first_in IS NOT NULL
AND last_out IS NOT NULL;

COMMIT;
log_engine_step('UPDATE_FLAGS_COMPLETE', 'Updated: ' || SQL%ROWCOUNT, p_work_date);
END update_processed_flags;

-- ==================== SYNC WITH ABSENCE SYSTEM ====================
PROCEDURE sync_with_absence_system(p_work_date DATE) IS
v_updated_count NUMBER := 0;
BEGIN
FOR rec IN (SELECT DISTINCT employee_no as emp_code, abs_type
FROM emp_absent
WHERE start_date = p_work_date
AND excused_flag = 'Y') LOOP
UPDATE emp_attend_daily d
SET attend_status = 'EXCUSED_ABSENCE',
notes = NVL(notes, '') || ' | Excused absence: ' || rec.abs_type,
updated_at = SYSDATE,
updated_by = 'ATTEND_ENG_PKG'
WHERE emp_code = rec.emp_code
AND work_date = p_work_date
AND attend_status = 'ABSENT';

IF SQL%ROWCOUNT > 0 THEN
v_updated_count := v_updated_count + 1;
END IF;
END LOOP;

COMMIT;
log_engine_step('SYNC_ABSENCE_COMPLETE', 'Updated: ' || v_updated_count, p_work_date);
END sync_with_absence_system;

-- ==================== MARK PROCESSED RAW ====================
PROCEDURE mark_processed_raw IS
v_updated_count NUMBER := 0;
BEGIN
IF v_classified_idx > 0 THEN
FORALL i IN 1 .. v_classified_idx
UPDATE attendance_staging s
SET s.process_flag = 'P',
s.punch_status = v_classified_punches(i).punch_status,
s.session_id = v_classified_punches(i).session_id
WHERE s.emp_code = v_classified_punches(i).emp_code
AND s.punch_time = v_classified_punches(i).punch_time
AND s.process_flag = 'N';

v_updated_count := SQL%ROWCOUNT;
COMMIT;
log_engine_step('MARK_PROCESSED_CLASSIFIED', 'Updated ' || v_updated_count || ' classified punches', g_work_date);
v_classified_punches.DELETE;
v_classified_idx := 0;
END IF;

log_engine_step('MARK_PROCESSED_COMPLETE', 'Classified: ' || v_updated_count, g_work_date);
EXCEPTION
WHEN OTHERS THEN
ROLLBACK;
log_engine_step('MARK_PROCESSED_FATAL', SQLERRM, g_work_date);
RAISE;
END mark_processed_raw;

-- ==================== COLLECT VIOLATIONS ====================
PROCEDURE COLLECT_violations (g_WORK_DATE DATE) IS
TYPE REC IS RECORD(
EMP_ID          NUMBER,
EMP_NAME        VARCHAR2(100),
WORK_DATE       DATE,
LATE_MIN        NUMBER,
EARLY_OUT_MIN   NUMBER,
SHIFT_ID        NUMBER
);
TYPE COLLECT_TAB IS TABLE OF REC INDEX BY PLS_INTEGER;
V_COLL COLLECT_TAB;

TYPE ID_TAB IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
V_IDS ID_TAB;

v_late_count        NUMBER := 0;
v_early_count       NUMBER := 0;
v_seq_val           NUMBER;
v_MARITAL_STATUS    NUMBER;
v_perm_count        NUMBER := 0;
v_mission_count     NUMBER := 0;
v_training_count    NUMBER := 0;
v_injury_count      NUMBER := 0;
v_vacation_count    NUMBER := 0;
v_exception_found   BOOLEAN := FALSE;
BEGIN
DBMS_OUTPUT.PUT_LINE('=========================================');
DBMS_OUTPUT.PUT_LINE('START COLLECT_VIOLATIONS FOR: ' || TO_CHAR(g_WORK_DATE, 'DD-MM-YYYY'));
DBMS_OUTPUT.PUT_LINE('=========================================');

SELECT EMP_CODE, EMP_NAME, TRUNC(WORK_DATE), LATE_MIN, EARLY_OUT_MIN, SHIFT_ID
BULK COLLECT INTO V_COLL
FROM emp_attend_daily d
WHERE LATE_MIN > 120
AND ATTEND_STATUS IN ('LATE', 'LATE_SEVERE')
and wardiya_result='MISMATCH'
AND TRUNC(WORK_DATE) = TRUNC(g_WORK_DATE)
AND NOT EXISTS (
SELECT 1 FROM ATT_VIOLATIONS v
WHERE v.EMP_CODE = d.EMP_CODE
AND TRUNC(v.WORK_DATE) = TRUNC(d.WORK_DATE)
AND v.VIOLATION_TYPE = 'LATE'
);

IF V_COLL.COUNT > 0 THEN
FOR i IN 1 .. V_COLL.COUNT LOOP
SELECT ATT_VIOLATIONS_SEQ.NEXTVAL INTO V_IDS(i) FROM DUAL;
END LOOP;

FORALL i IN 1 .. V_COLL.COUNT
INSERT INTO ATT_VIOLATIONS (
VIOLATION_ID, EMP_CODE, EMP_NAME, WORK_DATE, SHIFT_ID,
VIOLATION_TYPE, VIOLATION_MINUTES, STATUS, NOTES, CREATED_DATE
) VALUES (
V_IDS(i), V_COLL(i).EMP_ID, V_COLL(i).EMP_NAME, V_COLL(i).WORK_DATE, V_COLL(i).SHIFT_ID,
'LATE', V_COLL(i).LATE_MIN, 'PENDING',
'Late arrival: ' || V_COLL(i).LATE_MIN || ' minutes', SYSDATE
);

v_late_count := SQL%ROWCOUNT;
COMMIT;
DBMS_OUTPUT.PUT_LINE('LATE VIOLATIONS INSERTED: ' || v_late_count);
END IF;

V_COLL.DELETE;
V_IDS.DELETE;
v_early_count := 0;

SELECT EMP_CODE, EMP_NAME, TRUNC(WORK_DATE), LATE_MIN, EARLY_OUT_MIN, SHIFT_ID
BULK COLLECT INTO V_COLL
FROM emp_attend_daily d
WHERE EARLY_OUT_MIN >= 60
AND TRUNC(WORK_DATE) = TRUNC(g_WORK_DATE)
AND NOT EXISTS (
SELECT 1 FROM ATT_VIOLATIONS v
WHERE v.EMP_CODE = d.EMP_CODE
AND TRUNC(v.WORK_DATE) = TRUNC(d.WORK_DATE)
AND v.VIOLATION_TYPE = 'EARLY_OUT'
);

IF V_COLL.COUNT > 0 THEN
FOR i IN 1 .. V_COLL.COUNT LOOP
v_exception_found := FALSE;
v_MARITAL_STATUS  := NULL;

IF NOT v_exception_found THEN
SELECT COUNT(*) INTO v_perm_count
FROM EMP_PERMISSION p
WHERE p.EMPLOYEE_NO = V_COLL(i).EMP_ID
AND p.PERMISSION_DATE = TRUNC(V_COLL(i).WORK_DATE)
AND ROWNUM = 1;

IF v_perm_count > 0 THEN
v_exception_found := TRUE;
DBMS_OUTPUT.PUT_LINE('EXEMPTED (Permission): Emp ' || V_COLL(i).EMP_ID);
END IF;
END IF;

IF NOT v_exception_found THEN
SELECT COUNT(*) INTO v_mission_count
FROM EMP_MISSION m
WHERE m.EMPLOYEE_NO = V_COLL(i).EMP_ID
AND TRUNC(V_COLL(i).WORK_DATE) BETWEEN m.START_DATE AND NVL(m.END_DATE, m.START_DATE)
AND ROWNUM = 1;

IF v_mission_count > 0 THEN
v_exception_found := TRUE;
DBMS_OUTPUT.PUT_LINE('EXEMPTED (Mission): Emp ' || V_COLL(i).EMP_ID);
END IF;
END IF;

IF NOT v_exception_found THEN
SELECT COUNT(*) INTO v_training_count
FROM EMP_TRAINING t
WHERE t.EMPLOYEE_NO = V_COLL(i).EMP_ID
AND TRUNC(V_COLL(i).WORK_DATE) BETWEEN t.START_DATE AND NVL(t.END_DATE, t.START_DATE)
AND ROWNUM = 1;

IF v_training_count > 0 THEN
v_exception_found := TRUE;
DBMS_OUTPUT.PUT_LINE('EXEMPTED (Training): Emp ' || V_COLL(i).EMP_ID);
END IF;
END IF;

IF NOT v_exception_found THEN
SELECT COUNT(*) INTO v_injury_count
FROM EMP_infect_work inj
WHERE inj.EMPLOYEE_NO = V_COLL(i).EMP_ID
AND TRUNC(V_COLL(i).WORK_DATE) = TRUNC(inj.infecton_date)
AND ROWNUM = 1;

IF v_injury_count > 0 THEN
v_exception_found := TRUE;
DBMS_OUTPUT.PUT_LINE('EXEMPTED (Injury): Emp ' || V_COLL(i).EMP_ID);
END IF;
END IF;

IF NOT v_exception_found THEN
SELECT COUNT(*) INTO v_vacation_count
FROM EMP_VACATION v
WHERE v.EMPLOYEE_NO = V_COLL(i).EMP_ID
AND TRUNC(V_COLL(i).WORK_DATE) BETWEEN v.START_DATE AND NVL(v.END_DATE, v.START_DATE)
AND ROWNUM = 1;

IF v_vacation_count > 0 THEN
v_exception_found := TRUE;
DBMS_OUTPUT.PUT_LINE('EXEMPTED (Leave): Emp ' || V_COLL(i).EMP_ID);
END IF;
END IF;

IF NOT v_exception_found THEN
SELECT ATT_VIOLATIONS_SEQ.NEXTVAL INTO v_seq_val FROM DUAL;

INSERT INTO ATT_VIOLATIONS (
VIOLATION_ID, EMP_CODE, EMP_NAME, WORK_DATE, SHIFT_ID,
VIOLATION_TYPE, VIOLATION_MINUTES, STATUS, NOTES, CREATED_DATE
) VALUES (
v_seq_val, V_COLL(i).EMP_ID, V_COLL(i).EMP_NAME, V_COLL(i).WORK_DATE, V_COLL(i).SHIFT_ID,
'EARLY_OUT', V_COLL(i).EARLY_OUT_MIN, 'PENDING',
'Early out violation: ' || V_COLL(i).EARLY_OUT_MIN || ' minutes', SYSDATE
);

v_early_count := v_early_count + 1;
END IF;
END LOOP;

COMMIT;
DBMS_OUTPUT.PUT_LINE('EARLY OUT VIOLATIONS INSERTED: ' || v_early_count);
END IF;

EXCEPTION
WHEN OTHERS THEN
ROLLBACK;
DBMS_OUTPUT.PUT_LINE('ERROR: ' || SQLERRM);
RAISE;
END COLLECT_violations;

-- ==================== UTILITIES ====================
PROCEDURE optimize_memory_10g IS
BEGIN
cleanup_collections_10g;
BEGIN
EXECUTE IMMEDIATE 'ALTER SESSION SET SORT_AREA_SIZE = 1048576';
EXCEPTION
WHEN OTHERS THEN NULL;
END;
END optimize_memory_10g;

PROCEDURE cleanup_collections_10g IS
BEGIN
IF v_tab.COUNT > 0 THEN v_tab.DELETE; END IF;
IF v_shift.COUNT > 0 THEN v_shift.DELETE; END IF;
IF v_mid_collection.COUNT > 0 THEN v_mid_collection.DELETE; END IF;
IF v_classified_punches.COUNT > 0 THEN v_classified_punches.DELETE; END IF;
v_mid_idx := 0;
v_classified_idx := 0;
END cleanup_collections_10g;

-- ==================== REPROCESS PROCEDURES ====================
PROCEDURE quick_reprocess(p_work_date DATE) IS
v_before_count NUMBER;
v_after_count NUMBER;
v_reset_count NUMBER := 0;
BEGIN
log_engine_step('QUICK_REPROCESS_START', 'Quick reprocess for: ' ||
TO_CHAR(p_work_date, 'DD-MM-YYYY'), p_work_date);

SELECT COUNT(*) INTO v_before_count
FROM attendance_staging
WHERE TRUNC(work_date) = TRUNC(p_work_date) AND process_flag = 'N';

UPDATE attendance_staging s
SET s.process_flag = 'N'
WHERE s.process_flag = 'P'
AND TRUNC(s.work_date) = TRUNC(p_work_date)
AND EXISTS (
SELECT 1
FROM attendance_staging s2
WHERE s2.emp_code = s.emp_code
AND TRUNC(s2.work_date) = TRUNC(p_work_date)
AND s2.process_flag = 'N'
);

v_reset_count := SQL%ROWCOUNT;
COMMIT;

log_engine_step('QUICK_REPROCESS_FLAG_RESET',
'Reset ' || v_reset_count || ' records from P to N', p_work_date);

DELETE FROM attend_day_lock WHERE work_date = TRUNC(p_work_date);
COMMIT;

run_daily_attendance(p_work_date);

SELECT COUNT(*) INTO v_after_count
FROM attendance_staging
WHERE TRUNC(work_date) = TRUNC(p_work_date) AND process_flag = 'N';

log_engine_step('QUICK_REPROCESS_COMPLETE',
'Processed: ' || (v_before_count - v_after_count + v_reset_count), p_work_date);
EXCEPTION
WHEN OTHERS THEN
ROLLBACK;
log_engine_step('QUICK_REPROCESS_ERROR', SQLERRM, p_work_date);
RAISE;
END quick_reprocess;

PROCEDURE reprocess_stuck_punches(p_work_date DATE) IS
v_stuck_count      NUMBER;
v_processed_count  NUMBER := 0;
BEGIN
log_engine_step('REPROCESS_START', 'Reprocess for: ' ||
TO_CHAR(p_work_date, 'DD-MM-YYYY'), p_work_date);

DELETE FROM attend_day_lock WHERE work_date = TRUNC(p_work_date);
COMMIT;

UPDATE attendance_staging s
SET s.process_flag = 'N'
WHERE s.process_flag = 'P'
AND TRUNC(s.work_date) = TRUNC(p_work_date);

v_processed_count := SQL%ROWCOUNT;
COMMIT;

log_engine_step('REPROCESS_FLAG_RESET',
'Reset ' || v_processed_count || ' records from P to N', p_work_date);

SELECT COUNT(*) INTO v_stuck_count
FROM attendance_staging
WHERE TRUNC(work_date) = TRUNC(p_work_date) AND process_flag = 'N';

IF v_stuck_count > 0 THEN
run_daily_attendance(p_work_date);
END IF;

log_engine_step('REPROCESS_COMPLETE',
'Processed: ' || v_stuck_count || ' punches', p_work_date);
EXCEPTION
WHEN OTHERS THEN
ROLLBACK;
log_engine_step('REPROCESS_ERROR', SQLERRM, p_work_date);
RAISE;
END reprocess_stuck_punches;

PROCEDURE reprocess_with_next_day(p_work_date DATE) IS
BEGIN
log_engine_step('REPROCESS_PAIR_START',
'Reprocessing ' || TO_CHAR(p_work_date, 'DD-MM-YYYY') ||
' then ' || TO_CHAR(p_work_date + 1, 'DD-MM-YYYY'), p_work_date);

reprocess_stuck_punches(p_work_date);
reprocess_stuck_punches(p_work_date + 1);

log_engine_step('REPROCESS_PAIR_COMPLETE',
'Completed pair reprocess', p_work_date);
EXCEPTION
WHEN OTHERS THEN
log_engine_step('REPROCESS_PAIR_ERROR', SQLERRM, p_work_date);
RAISE;
END reprocess_with_next_day;

PROCEDURE diagnose_and_reprocess(p_work_date DATE) IS
v_process_flag_N NUMBER;
BEGIN
SELECT COUNT(*) INTO v_process_flag_N
FROM attendance_staging
WHERE TRUNC(work_date) = TRUNC(p_work_date) AND process_flag = 'N';

IF v_process_flag_N > 0 THEN
quick_reprocess(p_work_date);
ELSE
log_engine_step('DIAGNOSE_CLEAN', 'No stuck punches found', p_work_date);
END IF;
END diagnose_and_reprocess;

END attend_eng_pkg;
/
