-- Loads the sample feeds straight into RAW with INSERT (use when you cannot upload files to a stage).
-- Run ONCE. To reload: TRUNCATE TABLE RAW.MEMBER_FEED; TRUNCATE TABLE RAW.REDEMPTION_FEED;
USE DATABASE SKYPOINTS;
USE WAREHOUSE COMPUTE_WH;

INSERT INTO RAW.MEMBER_FEED (filler, rec_type, member_name, member_id, enrollment_date, last_flight_date,
    tier_code, agent_name, state, country, dob, is_active, post_code, source_file, source_file_row, feed_date)
SELECT NULL, 'D', $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, NULL, $11, $12, $13::DATE
FROM VALUES
 ('Elena','223457','20101012','20121013','GLD','Sam','CA','USA','03051985','A','members_20240115.txt',2,'2024-01-15'),
 ('Ravi','223458','20101012','20121013','SLV','Sam','TN','IND','03051985','A','members_20240115.txt',3,'2024-01-15'),
 ('Mateo','223459','20101012','20121013','GLD','Sam','NCR','PHIL','03051985','A','members_20240115.txt',4,'2024-01-15'),
 ('Nora','22345','20101012','20121013','PLT','Sam','ONT','CAN','03051985','A','members_20240115.txt',5,'2024-01-15'),
 ('Jacob','2256','20101012','20121013','SLV','Sam','VIC','AU','03051985','A','members_20240115.txt',6,'2024-01-15'),
 ('Elena','223457','20101012','20240110','GLD','Sam','ON','CAN','03051985','A','members_20240116.txt',2,'2024-01-16'),
 ('Ravi','223458','20101012','20121013','SLV','Sam','TN','IND','03051985','A','members_20240116.txt',3,'2024-01-16'),
 ('Ravi','223458','20101012','20231220','PLT','Sam','TN','IND','03051985','A','members_20240116.txt',4,'2024-01-16'),
 (NULL,'223460','20150301','20230101','GLD','Sam','NSW','AUS','01011990','A','members_20240116.txt',5,'2024-01-16'),
 ('Priya','223461','20151332','20230101','GLD','Sam','KA','IND','01011990','A','members_20240116.txt',6,'2024-01-16'),
 ('Liam','223462','20180101','20230101','GLD','Sam','CA','USA',NULL,NULL,'members_20240116.txt',7,'2024-01-16');

INSERT INTO RAW.REDEMPTION_FEED (doc, source_file, source_file_row)
SELECT PARSE_JSON($1), $2, $3 FROM VALUES
 ('{"member_id":"223457","feed_date":"20240115","redemptions":[{"txn_id":"RX10091","txn_date":"20240110","partner":"AeroLink","miles_redeemed":12000,"status":"COMPLETED"},{"txn_id":"RX10092","txn_date":"20240113","partner":"SkyPoints","miles_redeemed":5000,"status":"PENDING"}]}','redemptions_20240115.ndjson',1),
 ('{"member_id":"223458","feed_date":"20240115","redemptions":[]}','redemptions_20240115.ndjson',2),
 ('{"member_id":"999999","feed_date":"20240115","redemptions":[{"txn_id":"RX10093","txn_date":"20240114","partner":"AeroLink","miles_redeemed":-50,"status":"COMPLETED"}]}','redemptions_20240115.ndjson',3),
 ('{"member_id":"223457","feed_date":"20240116","redemptions":[{"txn_id":"RX10092","txn_date":"20240113","partner":"SkyPoints","miles_redeemed":5000,"status":"COMPLETED"}]}','redemptions_20240116.ndjson',1);
