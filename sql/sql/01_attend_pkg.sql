DROP PACKAGE MAS_FING.ATTEND_PKG;

CREATE OR REPLACE PACKAGE MAS_FING.attend_pkg IS

TYPE raw_rec IS RECORD (
employee_id     NUMBER,
first_name      VARCHAR2(100),
last_name       VARCHAR2(100),
department      VARCHAR2(100),
work_date       DATE,
week_day        VARCHAR2(100),
punch_time      DATE,
punch_status    VARCHAR2(20),
file_name       VARCHAR2(400),
raw_punch_code  NUMBER,
dept_id         NUMBER
);

TYPE raw_tab IS TABLE OF raw_rec;
v_raw raw_tab := raw_tab(); 

TYPE file_list IS TABLE OF VARCHAR2(400);

FUNCTION parse_time(p_date DATE, p_time_str VARCHAR2) RETURN DATE;
FUNCTION parse_date(p_date_str VARCHAR2) RETURN DATE;
FUNCTION get_name(p_file VARCHAR2) RETURN BOOLEAN;
PROCEDURE remove_duplicate_punches;
PROCEDURE log_file(p_file VARCHAR2);
PROCEDURE process_files(p_files IN file_list);
PROCEDURE import_files;
PROCEDURE process_all_files;

END attend_pkg;
/
DROP PACKAGE BODY MAS_FING.ATTEND_PKG;

CREATE OR REPLACE PACKAGE BODY MAS_FING.attend_pkg IS
    
    -- ==================== إزالة التكرار ====================
    PROCEDURE remove_duplicate_punches IS
    v_count_before NUMBER;
    v_count_after NUMBER;
    v_removed NUMBER := 0;
    BEGIN
    v_count_before := v_raw.COUNT;
    DBMS_OUTPUT.PUT_LINE('DEBUG: remove_duplicate_punches START, count=' || v_count_before);
    
    FOR i IN REVERSE 1 .. v_raw.COUNT LOOP
    FOR j IN 1 .. i-1 LOOP
    IF v_raw(i).employee_id = v_raw(j).employee_id 
    AND ABS((v_raw(i).punch_time - v_raw(j).punch_time) * 24 * 60) < 10 THEN
    DBMS_OUTPUT.PUT_LINE('DEBUG: Removing duplicate Emp=' || v_raw(i).employee_id ||
    ' Time=' || TO_CHAR(v_raw(i).punch_time, 'HH24:MI:SS') ||
    ' (diff=' || ROUND(ABS((v_raw(i).punch_time - v_raw(j).punch_time) * 24 * 60), 2) || ' min)');
    v_raw.DELETE(i);
    v_removed := v_removed + 1;
    EXIT;
    END IF;
    END LOOP;
    END LOOP;
    
    v_count_after := v_raw.COUNT;
    DBMS_OUTPUT.PUT_LINE('DEBUG: remove_duplicate_punches END, removed=' || v_removed || 
    ', count=' || v_count_after);
    END remove_duplicate_punches;
    
    -- ==================== دوال تحويل الوقت ====================
    FUNCTION parse_time(p_date DATE, p_time_str VARCHAR2) RETURN DATE IS
    v_time_str VARCHAR2(20);
    v_result DATE;
    v_date_str VARCHAR2(10);
    v_hour NUMBER;
    v_minute NUMBER;
    v_second NUMBER;
    v_ampm VARCHAR2(2);
    BEGIN
    v_time_str := TRIM(p_time_str);
    v_date_str := TO_CHAR(p_date, 'DD/MM/YYYY');
    
    BEGIN
    v_result := TO_DATE(v_date_str || ' ' || v_time_str, 'DD/MM/YYYY HH:MI:SS AM');
    RETURN v_result;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    
    BEGIN
    v_result := TO_DATE(v_date_str || ' ' || v_time_str, 'DD/MM/YYYY HH24:MI:SS');
    RETURN v_result;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    
    BEGIN
    v_hour := TO_NUMBER(REGEXP_SUBSTR(v_time_str, '^[0-9]{1,2}'));
    v_minute := TO_NUMBER(NVL(REGEXP_SUBSTR(v_time_str, ':([0-9]{2})', 1, 1, NULL, 1), 0));
    v_second := TO_NUMBER(NVL(REGEXP_SUBSTR(v_time_str, ':([0-9]{2})', 1, 2, NULL, 1), 0));
    v_ampm := UPPER(REGEXP_SUBSTR(v_time_str, '(AM|PM)'));
    
    IF v_ampm = 'PM' AND v_hour < 12 THEN v_hour := v_hour + 12; END IF;
    IF v_ampm = 'AM' AND v_hour = 12 THEN v_hour := 0; END IF;
    
    v_result := TO_DATE(v_date_str || ' ' || 
    TO_CHAR(v_hour, '00') || ':' ||
    TO_CHAR(v_minute, '00') || ':' ||
    TO_CHAR(v_second, '00'), 
    'DD/MM/YYYY HH24:MI:SS');
    RETURN v_result;
    EXCEPTION WHEN OTHERS THEN RETURN NULL;
    END;
    END parse_time;
    
    FUNCTION parse_date(p_date_str VARCHAR2) RETURN DATE IS
    v_date_str VARCHAR2(20);
    v_result DATE;
    BEGIN
    v_date_str := TRIM(p_date_str);
    BEGIN
    v_result := TO_DATE(v_date_str, 'DD/MM/YYYY');
    RETURN v_result;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    BEGIN
    v_result := TO_DATE(v_date_str, 'MM/DD/YYYY');
    RETURN v_result;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    
    BEGIN
    v_result := TO_DATE(v_date_str, 'MM-DD-YYYY');
    RETURN v_result;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    
     BEGIN
    v_result := TO_DATE(v_date_str, 'DD-MM-YYYY');
    RETURN v_result;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    
    RETURN NULL;
    END parse_date;
    
    FUNCTION get_name(p_file VARCHAR2) RETURN BOOLEAN IS
    v_count NUMBER;
    BEGIN
    SELECT COUNT(*) INTO v_count FROM ATT_FILE_LOG WHERE file_name = p_file;
    RETURN (v_count > 0);
    END get_name;
    
    PROCEDURE log_file(p_file VARCHAR2) IS
    BEGIN
    INSERT INTO ATT_FILE_LOG(file_name) VALUES (p_file);
    COMMIT;
    END log_file;
    
    -- ==================== قراءة الملفات ====================
    PROCEDURE process_files(p_files IN file_list) IS
    l_file          UTL_FILE.file_type;
    l_location      VARCHAR2(100) := 'MYDIR';
    l_text          VARCHAR2(32767);
    v_line_number   NUMBER := 0;
    v_file_ext      VARCHAR2(10);
    v_emp_id        VARCHAR2(4000);
    v_date_str      VARCHAR2(4000);
    v_time_str      VARCHAR2(4000);
    l_emp_code      NUMBER;
    l_work_date     DATE;
    l_punch_time    DATE;
    l_index         PLS_INTEGER;
    BEGIN
    v_raw.DELETE;
    v_raw := raw_tab();
    
    FOR i IN 1 .. p_files.COUNT LOOP
    IF get_name(p_files(i)) THEN
    DBMS_OUTPUT.PUT_LINE('WARNING: File already imported: ' || p_files(i));
    CONTINUE;
    END IF;
    
    v_file_ext := UPPER(SUBSTR(p_files(i), -4));
    
    BEGIN
    l_file := UTL_FILE.fopen(l_location, p_files(i), 'r');
    EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('ERROR: Cannot open file ' || p_files(i) || ': ' || SQLERRM);
    CONTINUE;
    END;
    
    v_line_number := 0;
    
    LOOP
    BEGIN
    UTL_FILE.get_line(l_file, l_text);
    v_line_number := v_line_number + 1;
    EXCEPTION WHEN NO_DATA_FOUND THEN EXIT;
    END;
    
    IF TRIM(l_text) IS NULL THEN CONTINUE; END IF;
    
    l_text := REPLACE(l_text, CHR(13), '');
    l_text := REPLACE(l_text, CHR(10), '');
    
    IF v_line_number = 1 THEN
    l_text := REGEXP_REPLACE(l_text, '^' || CHR(239) || CHR(187) || CHR(191), '');
    END IF;
    IF INSTR(l_text, ',') > 0 THEN

    ----------------------------------------------------------------
    -- FORMAT 1
    -- CSV
    -- 3480,09/08/2026,08:05:06
    ----------------------------------------------------------------

    v_emp_id   := TRIM(REGEXP_SUBSTR(l_text, '[^,]+', 1, 1));
    v_date_str := TRIM(REGEXP_SUBSTR(l_text, '[^,]+', 1, 2));
    v_time_str := TRIM(REGEXP_SUBSTR(l_text, '[^,]+', 1, 3));


ELSIF REGEXP_LIKE(
          l_text,
          '^[[:space:]]*[0-9]+[[:space:]]+[0-9]{2}/[0-9]{2}/[0-9]{4}[[:space:]]+[0-9]{1,2}:[0-9]{2}(:[0-9]{2})?'
      )
THEN

    ----------------------------------------------------------------
    -- FORMAT 2
    -- TAB / SPACE
    -- 3480    09/08/2026    08:05:06
    ----------------------------------------------------------------

    v_emp_id := REGEXP_SUBSTR(
        l_text,
        '[0-9]+',
        1,
        1
    );

    v_date_str := REGEXP_SUBSTR(
        l_text,
        '[0-9]{2}/[0-9]{2}/[0-9]{4}',
        1,
        1
    );

    v_time_str := REGEXP_SUBSTR(
        l_text,
        '[0-9]{1,2}:[0-9]{2}(:[0-9]{2})?',
        1,
        1
    );


ELSIF REGEXP_LIKE(
          l_text,
          '^[[:space:]]*[0-9]+[[:space:]]+[0-9]{2}-[0-9]{2}-[0-9]{4}[[:space:]]+[0-9]{1,2}:[0-9]{2}:[0-9]{2}'
      )
THEN

    ----------------------------------------------------------------
    -- FORMAT 3
    -- TAB / SPACE
    -- 3942    21-07-2026    07:31:41
    ----------------------------------------------------------------

    v_emp_id := REGEXP_SUBSTR(
        l_text,
        '[0-9]+',
        1,
        1
    );

    v_date_str := REGEXP_SUBSTR(
        l_text,
        '[0-9]{2}-[0-9]{2}-[0-9]{4}',
        1,
        1
    );

    v_time_str := REGEXP_SUBSTR(
        l_text,
        '[0-9]{1,2}:[0-9]{2}:[0-9]{2}',
        1,
        1
    );


ELSIF REGEXP_LIKE(
          l_text,
          '[0-9]{2}-[0-9]{2}-[0-9]{4}'
      )
THEN

    ----------------------------------------------------------------
    -- FORMAT 4
    -- EMP + DATE + TIME
    -- 363520-07-202608:25:55
    ----------------------------------------------------------------

    v_date_str := REGEXP_SUBSTR(
        l_text,
        '[0-9]{2}-[0-9]{2}-[0-9]{4}',
        1,
        1
    );

    v_time_str := REGEXP_SUBSTR(
        l_text,
        '[0-9]{2}:[0-9]{2}:[0-9]{2}',
        1,
        1
    );

    IF v_date_str IS NOT NULL THEN

        v_emp_id := SUBSTR(
            l_text,
            1,
            INSTR(l_text, v_date_str) - 1
        );

        v_emp_id := REGEXP_REPLACE(
            v_emp_id,
            '[^0-9]',
            ''
        );

    END IF;


ELSE

    ----------------------------------------------------------------
    -- FORMAT 5
    -- OLD FORMAT
    -- لا نحذفه
    ----------------------------------------------------------------

    v_date_str := REGEXP_SUBSTR(
        l_text,
        '[0-9]{2}/[0-9]{2}/[0-9]{4}'
    );

    v_time_str := REGEXP_SUBSTR(
        l_text,
        '[0-9]{1,2}:[0-9]{2}(:[0-9]{2})?[[:space:]]*(AM|PM)?'
    );

    IF v_date_str IS NOT NULL THEN

        v_emp_id := SUBSTR(
            l_text,
            1,
            INSTR(l_text, v_date_str) - 1
        );

        v_emp_id := REGEXP_REPLACE(
            v_emp_id,
            '[^0-9]',
            ''
        );

        IF LENGTH(v_emp_id) > 4 THEN
            v_emp_id := SUBSTR(v_emp_id, 1, 4);
        END IF;

    END IF;

END IF;

    v_emp_id   := REGEXP_REPLACE(v_emp_id, '[^0-9]', '');
    v_date_str := TRIM(v_date_str);
    v_time_str := TRIM(v_time_str);
    DBMS_OUTPUT.PUT_LINE(
    'LINE ' || v_line_number ||
    ' => [' || l_text || ']'
);

DBMS_OUTPUT.PUT_LINE(
    'PARSED => EMP=[' || NVL(v_emp_id, 'NULL') ||
    '] DATE=[' || NVL(v_date_str, 'NULL') ||
    '] TIME=[' || NVL(v_time_str, 'NULL') || ']'
);
    IF v_emp_id IS NULL OR v_date_str IS NULL OR v_time_str IS NULL THEN
    INSERT INTO ATT_PARSE_ERRORS(error_id, file_name, error_line, error_message)
    VALUES (attend_parse_errors_seq.NEXTVAL, p_files(i), l_text, 'Failed to extract fields');
    CONTINUE;
    END IF;
    
    BEGIN l_emp_code := TO_NUMBER(v_emp_id); EXCEPTION WHEN OTHERS THEN l_emp_code := NULL; END;
    l_work_date := parse_date(v_date_str);
    
    IF l_work_date IS NOT NULL THEN
    l_punch_time := parse_time(l_work_date, v_time_str);
    ELSE
    l_punch_time := NULL;
    END IF;
    
    IF l_emp_code IS NOT NULL AND l_punch_time IS NOT NULL THEN
    v_raw.EXTEND;
    l_index := v_raw.COUNT;
    v_raw(l_index).employee_id     := l_emp_code;
    v_raw(l_index).first_name      := '';
    v_raw(l_index).last_name       := '';
    v_raw(l_index).department      := '';
    v_raw(l_index).work_date       := l_work_date;
    v_raw(l_index).week_day        := TO_CHAR(l_work_date, 'DAY', 'NLS_DATE_LANGUAGE=ARABIC');
    v_raw(l_index).punch_time      := l_punch_time;
    v_raw(l_index).punch_status    := 'UNKNOWN';
    v_raw(l_index).file_name       := p_files(i);
    v_raw(l_index).raw_punch_code  := NULL;
    v_raw(l_index).dept_id         := NULL;
    ELSE
    INSERT INTO ATT_PARSE_ERRORS(error_id, file_name, error_line, error_message)
    VALUES (attend_parse_errors_seq.NEXTVAL, p_files(i), l_text, 'Data conversion failed');
    END IF;
    
    END LOOP;
    
    UTL_FILE.fclose(l_file);
    log_file(p_files(i));
    DBMS_OUTPUT.PUT_LINE('File processed: ' || p_files(i) || ' (' || v_line_number || ' lines)');
    
    END LOOP;
    END process_files;
    
    -- ==================== IMPORT_FILES (بسيط - يخزن كـ UNKNOWN) ====================
    PROCEDURE import_files IS
    v_duplicate_count NUMBER := 0;
    v_inserted_count  NUMBER := 0;
    v_filtered_count  NUMBER := 0;
    v_before_count    NUMBER;
    v_missing_emp     NUMBER := 0;
    
    -- مصفوفات للإدراج الجماعي
    TYPE num_arr IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    TYPE varchar_arr IS TABLE OF VARCHAR2(400) INDEX BY PLS_INTEGER;
    TYPE date_arr IS TABLE OF DATE INDEX BY PLS_INTEGER;
    TYPE char_arr IS TABLE OF CHAR(1) INDEX BY PLS_INTEGER;
    
    v_stage_id_arr       num_arr;
    v_emp_code_arr       num_arr;
    v_first_name_arr     varchar_arr;
    v_last_name_arr      varchar_arr;
    v_department_arr     varchar_arr;
    v_work_date_arr      date_arr;
    v_weekday_arr        varchar_arr;
    v_punch_time_arr     date_arr;
    v_punch_status_arr   varchar_arr;
    v_file_name_arr      varchar_arr;
    v_load_date_arr      date_arr;
    v_process_flag_arr   varchar_arr;
    v_session_id_arr     num_arr;
    v_session_open_arr   char_arr;
    
    v_idx NUMBER := 0;
    v_valid NUMBER := 0;
    v_emp_exists NUMBER;
    
    TYPE temp_rec IS RECORD (
    emp_code       NUMBER,
    punch_time     DATE,
    file_name      VARCHAR2(400),
    punch_hour     NUMBER,
    punch_date     DATE
    );
    
    TYPE temp_tab IS TABLE OF temp_rec INDEX BY PLS_INTEGER;
    v_temp_data temp_tab;
    
    v_count NUMBER := 0;
    v_temp_idx PLS_INTEGER;
    
    TYPE valid_flag_arr IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    v_valid_flag valid_flag_arr;
    
    BEGIN
    IF v_raw.COUNT = 0 THEN
    DBMS_OUTPUT.PUT_LINE('No data to import');
    RETURN;
    END IF;
    
    remove_duplicate_punches;
    v_before_count := v_raw.COUNT;
    
    DBMS_OUTPUT.PUT_LINE('Processing ' || v_before_count || ' records...');
    
    -- جمع البيانات
    v_temp_idx := v_raw.FIRST;
    
    WHILE v_temp_idx IS NOT NULL LOOP
    IF v_raw.EXISTS(v_temp_idx)
    AND v_raw(v_temp_idx).employee_id IS NOT NULL
    AND v_raw(v_temp_idx).punch_time IS NOT NULL
    THEN
    v_count := v_count + 1;
    v_temp_data(v_count).emp_code   := v_raw(v_temp_idx).employee_id;
    v_temp_data(v_count).punch_time := v_raw(v_temp_idx).punch_time;
    v_temp_data(v_count).file_name  := v_raw(v_temp_idx).file_name;
    v_temp_data(v_count).punch_date := TRUNC(v_raw(v_temp_idx).punch_time);
    v_temp_data(v_count).punch_hour := TO_NUMBER(TO_CHAR(v_raw(v_temp_idx).punch_time, 'HH24'));
    END IF;
    v_temp_idx := v_raw.NEXT(v_temp_idx);
    END LOOP;
    
    DBMS_OUTPUT.PUT_LINE('Collected ' || v_count || ' records after dedup');
    
    -- ترتيب البيانات
    FOR i IN 1 .. v_count - 1 LOOP
    FOR j IN i + 1 .. v_count LOOP
    IF v_temp_data(i).emp_code > v_temp_data(j).emp_code
    OR (v_temp_data(i).emp_code = v_temp_data(j).emp_code
    AND v_temp_data(i).punch_time > v_temp_data(j).punch_time)
    THEN
    DECLARE v_temp temp_rec; 
    BEGIN
    v_temp := v_temp_data(i);
    v_temp_data(i) := v_temp_data(j);
    v_temp_data(j) := v_temp;
    END;
    END IF;
    END LOOP;
    END LOOP;
    
    DBMS_OUTPUT.PUT_LINE('Data sorted');
    
    v_idx := 0;
    
    FOR i IN 1 .. v_count LOOP
    -- تحقق الموظف من EMP_MASTER (جدول الشركة)
    BEGIN
    SELECT 1 INTO v_emp_exists
    FROM EMP_MASTER
    WHERE EMPLOYEE_NO = v_temp_data(i).emp_code AND ROWNUM = 1;
    EXCEPTION WHEN NO_DATA_FOUND THEN
    INSERT INTO ATT_PARSE_ERRORS(error_id, file_name, error_line, error_message)
    VALUES (attend_parse_errors_seq.NEXTVAL, v_temp_data(i).file_name, i,
    'Employee ' || v_temp_data(i).emp_code || ' not found in EMP_MASTER');
    v_missing_emp := v_missing_emp + 1;
    CONTINUE;
    END;
    
    -- تجهيز البيانات للإدراج
    v_idx := v_idx + 1;
    
    v_first_name_arr(v_idx) := '';
    v_last_name_arr(v_idx) := '';
    v_department_arr(v_idx) := '';
    
    SELECT att_seq.NEXTVAL INTO v_stage_id_arr(v_idx) FROM dual;
    v_emp_code_arr(v_idx) := v_temp_data(i).emp_code;
    v_work_date_arr(v_idx) := v_temp_data(i).punch_date;
    v_weekday_arr(v_idx) := TO_CHAR(v_temp_data(i).punch_time, 'DAY', 'NLS_DATE_LANGUAGE=ARABIC');
    v_punch_time_arr(v_idx) := v_temp_data(i).punch_time;
    v_punch_status_arr(v_idx) := 'UNKNOWN';
    v_file_name_arr(v_idx) := v_temp_data(i).file_name;
    v_load_date_arr(v_idx) := SYSDATE;
    v_process_flag_arr(v_idx) := 'N';
    v_session_id_arr(v_idx) := 0;
    v_session_open_arr(v_idx) := 'N';
    
    v_valid := v_valid + 1;
    
    IF MOD(v_idx, 1000) = 0 THEN
    DBMS_OUTPUT.PUT_LINE('Processed ' || v_idx || ' records...');
    END IF;
    END LOOP;
    
    DBMS_OUTPUT.PUT_LINE('Prepared ' || v_idx || ' records for insertion');
    
    -- الإدراج النهائي
    IF v_idx > 0 THEN
    
    DBMS_OUTPUT.PUT_LINE('Checking for duplicates...');
    
    -- التحقق من التكرار
    FOR j IN 1 .. v_idx LOOP
    DECLARE v_exists NUMBER;
    BEGIN
    SELECT COUNT(*) INTO v_exists
    FROM ATT_ATTENDANCE_STAGING
    WHERE emp_code = v_emp_code_arr(j)
    AND punch_time = v_punch_time_arr(j)
    AND ROWNUM = 1;
    
    IF v_exists = 0 THEN
    v_valid_flag(j) := 1;
    ELSE
    v_valid_flag(j) := 0;
    v_duplicate_count := v_duplicate_count + 1;
    END IF;
    END;
    END LOOP;
    
    DBMS_OUTPUT.PUT_LINE('Inserting ' || v_idx || ' records...');
    
    -- الإدراج
    FORALL j IN 1 .. v_idx
    INSERT INTO ATT_ATTENDANCE_STAGING (
    stage_id, emp_code, first_name, last_name, department,
    work_date, weekday, punch_time, punch_status, file_name,
    load_date, process_flag, session_id, session_open
    )
    SELECT 
    v_stage_id_arr(j), v_emp_code_arr(j), v_first_name_arr(j), v_last_name_arr(j), v_department_arr(j),
    v_work_date_arr(j), v_weekday_arr(j), v_punch_time_arr(j), v_punch_status_arr(j), v_file_name_arr(j),
    v_load_date_arr(j), v_process_flag_arr(j), v_session_id_arr(j), v_session_open_arr(j)
    FROM DUAL 
    WHERE v_valid_flag(j) = 1;
    
    v_inserted_count := SQL%ROWCOUNT;
    COMMIT;
    
    DBMS_OUTPUT.PUT_LINE('Inserted ' || v_inserted_count || ' records');
    END IF;
    
    DBMS_OUTPUT.PUT_LINE('=============================================================');
    DBMS_OUTPUT.PUT_LINE('IMPORT SUMMARY:');
    DBMS_OUTPUT.PUT_LINE('   Raw records after dedup: ' || v_before_count);
    DBMS_OUTPUT.PUT_LINE('   Valid records processed: ' || v_valid);
    DBMS_OUTPUT.PUT_LINE('   Inserted into staging: ' || v_inserted_count);
    DBMS_OUTPUT.PUT_LINE('   Duplicates skipped: ' || v_duplicate_count);
    DBMS_OUTPUT.PUT_LINE('   Missing employees: ' || v_missing_emp);
    DBMS_OUTPUT.PUT_LINE('=============================================================');
    
    EXCEPTION
    WHEN OTHERS THEN
    ROLLBACK;
    DBMS_OUTPUT.PUT_LINE('ERROR in import_files: ' || SQLERRM);
    DBMS_OUTPUT.PUT_LINE('Backtrace: ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
    RAISE;
    END import_files;
    
    -- ==================== process_all_files ====================
    PROCEDURE process_all_files IS
    v_files         file_list := file_list();
    v_count         NUMBER := 0;
    v_batch_size    CONSTANT NUMBER := 1;
    v_success_count NUMBER := 0;
    v_error_count   NUMBER := 0;
    v_file_name     VARCHAR2(400);
    v_error_msg     VARCHAR2(4000);
    
    CURSOR c_pending_files IS
    SELECT file_name 
    FROM ATT_PENDING_FILES
    WHERE status = 'PENDING'
    AND rownum <= v_batch_size 
    ORDER BY added_date;
    BEGIN
    OPEN c_pending_files;
    LOOP
    FETCH c_pending_files INTO v_file_name;
    EXIT WHEN c_pending_files%NOTFOUND;
    v_files.EXTEND;
    v_files(v_files.COUNT) := v_file_name;
    v_count := v_count + 1;
    END LOOP;
    CLOSE c_pending_files;
    
    IF v_files.COUNT > 0 THEN
    BEGIN
    process_files(v_files);
    import_files;
    FOR i IN 1..v_files.COUNT LOOP
    UPDATE ATT_PENDING_FILES 
    SET status = 'PROCESSED', processed_date = SYSDATE, error_message = NULL
    WHERE file_name = v_files(i);
    END LOOP;
    COMMIT;
    EXCEPTION WHEN OTHERS THEN
    FOR i IN 1..v_files.COUNT LOOP
    UPDATE ATT_PENDING_FILES 
    SET status = 'ERROR'
    WHERE file_name = v_files(i);
    END LOOP;
    COMMIT;
    END;
    END IF;
    END process_all_files;
    
    END attend_pkg;
/
