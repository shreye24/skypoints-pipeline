-- =====================================================================
-- FALLBACK: load the sample feeds with plain INSERTs instead of stage upload + COPY (01a).
-- Rows are the exact lines of the files in data/sample, so 01b_split_lines.sql behaves identically.
-- Use ONE of: 01a (normal path) or this script. Running both double-loads the sample data.
-- =====================================================================
USE DATABASE SKYPOINTS;
USE WAREHOUSE COMPUTE_WH;

-- DAY 1 members (15 Jan)
INSERT INTO RAW.MEMBER_LINE (raw_line, source_file, source_file_row, feed_date) VALUES
  ('|H|Member_Name|Member_Id|Enrollment_Date|Last_Flight_Date|Tier_Code|Agent_Name|State|Country|DOB|Is_Active', 'members_20240115.txt', 1, '2024-01-15'::DATE),
  ('|D|Elena|223457|20101012|20121013|GLD|Sam|CA|USA|03051985|A', 'members_20240115.txt', 2, '2024-01-15'::DATE),
  ('|D|Ravi|223458|20101012|20121013|SLV|Sam|TN|IND|03051985|A', 'members_20240115.txt', 3, '2024-01-15'::DATE),
  ('|D|Mateo|223459|20101012|20121013|GLD|Sam|NCR|PHIL|03051985|A', 'members_20240115.txt', 4, '2024-01-15'::DATE),
  ('|D|Nora|22345|20101012|20121013|PLT|Sam|ONT|CAN|03051985|A', 'members_20240115.txt', 5, '2024-01-15'::DATE),
  ('|D|Jacob|2256|20101012|20121013|SLV|Sam|VIC|AU|03051985|A', 'members_20240115.txt', 6, '2024-01-15'::DATE);

-- DAY 2 members (16 Jan) - run day 1 through the pipeline first to see the country move
INSERT INTO RAW.MEMBER_LINE (raw_line, source_file, source_file_row, feed_date) VALUES
  ('|H|Member_Name|Member_Id|Enrollment_Date|Last_Flight_Date|Tier_Code|Agent_Name|State|Country|DOB|Is_Active', 'members_20240116.txt', 1, '2024-01-16'::DATE),
  ('|D|Elena|223457|20101012|20240110|GLD|Sam|ON|CAN|03051985|A', 'members_20240116.txt', 2, '2024-01-16'::DATE),
  ('|D|Ravi|223458|20101012|20121013|SLV|Sam|TN|IND|03051985|A', 'members_20240116.txt', 3, '2024-01-16'::DATE),
  ('|D|Ravi|223458|20101012|20231220|PLT|Sam|TN|IND|03051985|A', 'members_20240116.txt', 4, '2024-01-16'::DATE),
  ('|D||223460|20150301|20230101|GLD|Sam|NSW|AUS|01011990|A', 'members_20240116.txt', 5, '2024-01-16'::DATE),
  ('|D|Priya|223461|20151332|20230101|GLD|Sam|KA|IND|01011990|A', 'members_20240116.txt', 6, '2024-01-16'::DATE),
  ('|D|Liam|223462|20180101|20230101|GLD|Sam|CA|USA', 'members_20240116.txt', 7, '2024-01-16'::DATE);

-- EXCEL extracts converted to flat files (python -m skypoints.convert) - load after day 2
INSERT INTO RAW.MEMBER_LINE (raw_line, source_file, source_file_row, feed_date) VALUES
  ('|H|Member_Name|Member_Id|Enrollment_Date|Last_Flight_Date|Tier_Code|Agent_Name|State|Country|DOB|Is_Active|Member_Type', 'members_AUS_20240116.txt', 1, '2024-01-16'::DATE),
  ('|D|Mike|AUS-1|20220511|20220801|PLT|||AUS|||', 'members_AUS_20240116.txt', 2, '2024-01-16'::DATE),
  ('|D|Jonnathan|AUS-2|2021-13-13|20220105|GLD|||AUS|13121997||', 'members_AUS_20240116.txt', 3, '2024-01-16'::DATE),
  ('|D|Cristina|AUS-3|20220312|20220320|SLV|||AUS|12031998||', 'members_AUS_20240116.txt', 4, '2024-01-16'::DATE),
  ('|H|Member_Name|Member_Id|Enrollment_Date|Last_Flight_Date|Tier_Code|Agent_Name|State|Country|DOB|Is_Active|Member_Type', 'members_USA_20240116.txt', 1, '2024-01-16'::DATE),
  ('|D|Sam|USA-1|20220615|20220820|PLT|||USA|||', 'members_USA_20240116.txt', 2, '2024-01-16'::DATE),
  ('|D|John|USA-2|20220105|20220115|SLV|||USA|||', 'members_USA_20240116.txt', 3, '2024-01-16'::DATE),
  ('|D|Mike|USA-3|20211228|20211230|GLD|||USA|||', 'members_USA_20240116.txt', 4, '2024-01-16'::DATE),
  ('|H|Member_Name|Member_Id|Enrollment_Date|Last_Flight_Date|Tier_Code|Agent_Name|State|Country|DOB|Is_Active|Member_Type', 'members_IND_20240116.txt', 1, '2024-01-16'::DATE),
  ('|D|Vikas|IND-1|20220101|20220615|SLV|||IND|01121998||I', 'members_IND_20240116.txt', 2, '2024-01-16'::DATE),
  ('|D|Rahul|IND-2|20220305|20220310|GLD|||IND|13081982||C', 'members_IND_20240116.txt', 3, '2024-01-16'::DATE),
  ('|D|Sameer|IND-3|20220220|20220225|GLD|||IND|13081952||I', 'members_IND_20240116.txt', 4, '2024-01-16'::DATE);

-- Redemption documents (NDJSON), both days
INSERT INTO RAW.REDEMPTION_FEED (doc, source_file, source_file_row)
SELECT PARSE_JSON($1), $2, $3 FROM VALUES
  ('{"member_id": "223457", "feed_date": "20240115", "redemptions": [{"txn_id": "RX10091", "txn_date": "20240110", "partner": "AeroLink", "miles_redeemed": 12000, "status": "COMPLETED"}, {"txn_id": "RX10092", "txn_date": "20240113", "partner": "SkyPoints", "miles_redeemed": 5000, "status": "PENDING"}]}', 'redemptions_20240115.ndjson', 1),
  ('{"member_id": "223458", "feed_date": "20240115", "redemptions": []}', 'redemptions_20240115.ndjson', 2),
  ('{"member_id": "999999", "feed_date": "20240115", "redemptions": [{"txn_id": "RX10093", "txn_date": "20240114", "partner": "AeroLink", "miles_redeemed": -50, "status": "COMPLETED"}]}', 'redemptions_20240115.ndjson', 3),
  ('{"member_id": "223457", "feed_date": "20240116", "redemptions": [{"txn_id": "RX10092", "txn_date": "20240113", "partner": "SkyPoints", "miles_redeemed": 5000, "status": "COMPLETED"}]}', 'redemptions_20240116.ndjson', 1);
