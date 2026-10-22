-- ScoutOps schema. Executed automatically by the postgres image on first
-- initialization of an empty data volume (mounted in /docker-entrypoint-initdb.d).

CREATE TABLE IF NOT EXISTS issues (
    id            INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title         VARCHAR(150) NOT NULL,
    description   TEXT         NOT NULL DEFAULT '',
    category      VARCHAR(20)  NOT NULL
                  CHECK (category IN ('ELECTRICAL','PLUMBING','INTERNET','CLEANING','FURNITURE','EQUIPMENT','SECURITY','OTHER')),
    location      VARCHAR(150) NOT NULL,
    priority      VARCHAR(10)  NOT NULL DEFAULT 'MEDIUM'
                  CHECK (priority IN ('LOW','MEDIUM','HIGH','CRITICAL')),
    status        VARCHAR(20)  NOT NULL DEFAULT 'OPEN'
                  CHECK (status IN ('OPEN','ASSIGNED','IN_PROGRESS','RESOLVED','CLOSED')),
    reporter_name VARCHAR(100) NOT NULL,
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_issues_status     ON issues (status);
CREATE INDEX IF NOT EXISTS idx_issues_priority   ON issues (priority);
CREATE INDEX IF NOT EXISTS idx_issues_category   ON issues (category);
CREATE INDEX IF NOT EXISTS idx_issues_created_at ON issues (created_at DESC);

-- Demo data (only inserted when the table is empty)
INSERT INTO issues (title, description, category, location, priority, status, reporter_name, created_at, updated_at)
SELECT * FROM (VALUES
 ('Projector not turning on', 'Ceiling projector in Room 204 shows no signal and the power light stays off.', 'EQUIPMENT', 'Block A, Room 204', 'HIGH', 'OPEN', 'Ananya Rao', NOW() - INTERVAL '6 days', NOW() - INTERVAL '6 days'),
 ('Flickering tube lights in corridor', 'Three tube lights on the second-floor corridor flicker constantly.', 'ELECTRICAL', 'Block B, 2nd Floor Corridor', 'MEDIUM', 'ASSIGNED', 'Karthik Subramanian', NOW() - INTERVAL '5 days', NOW() - INTERVAL '4 days'),
 ('Water leakage from washroom tap', 'Continuous leak from the second tap; water pooling on the floor.', 'PLUMBING', 'Library, Ground Floor Washroom', 'HIGH', 'IN_PROGRESS', 'Meera Nair', NOW() - INTERVAL '4 days', NOW() - INTERVAL '1 day'),
 ('Wi-Fi unavailable in computer lab', 'Access point appears offline; no student devices can connect.', 'INTERNET', 'Computer Lab 3', 'CRITICAL', 'OPEN', 'Rahul Verma', NOW() - INTERVAL '3 days', NOW() - INTERVAL '3 days'),
 ('Broken bench in seminar hall', 'Two benches have cracked legs and are unsafe to sit on.', 'FURNITURE', 'Seminar Hall, Row 4', 'LOW', 'OPEN', 'Divya Menon', NOW() - INTERVAL '3 days', NOW() - INTERVAL '3 days'),
 ('Overflowing dustbins near canteen', 'Dustbins have not been emptied for two days.', 'CLEANING', 'Canteen Entrance', 'MEDIUM', 'RESOLVED', 'Imran Sheikh', NOW() - INTERVAL '7 days', NOW() - INTERVAL '5 days'),
 ('CCTV camera offline at main gate', 'Camera 2 at the main gate shows a black screen on the monitoring desk.', 'SECURITY', 'Main Gate', 'CRITICAL', 'IN_PROGRESS', 'Suresh Kumar', NOW() - INTERVAL '2 days', NOW() - INTERVAL '1 day'),
 ('Oscilloscope probe damaged', 'Channel 2 probe of bench oscilloscope 5 has a broken connector.', 'EQUIPMENT', 'Electronics Lab', 'MEDIUM', 'ASSIGNED', 'Pooja Iyer', NOW() - INTERVAL '2 days', NOW() - INTERVAL '1 day'),
 ('Staircase handrail loose', 'Handrail on the east staircase wobbles when held.', 'OTHER', 'Block C, East Staircase', 'HIGH', 'OPEN', 'Arjun Das', NOW() - INTERVAL '1 day', NOW() - INTERVAL '1 day'),
 ('Air conditioner dripping water', 'AC unit drips onto the faculty desks near the window.', 'ELECTRICAL', 'Faculty Room, Block A', 'LOW', 'CLOSED', 'Lakshmi Priya', NOW() - INTERVAL '10 days', NOW() - INTERVAL '8 days')
) AS demo(title, description, category, location, priority, status, reporter_name, created_at, updated_at)
WHERE NOT EXISTS (SELECT 1 FROM issues);
