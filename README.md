# UCM Photo of the Week

A weekly photo contest for the Kent State UCM photo team. It's a single static page hosted on GitHub Pages, with Supabase handling sign-in, photo storage and votes.

**How a week runs (Eastern time)**

| When | What happens |
|---|---|
| Mon–Thu | Each photographer submits up to 4 photos |
| Fri–Sun | Everyone rates every photo 0–7 stars and submits one ballot. Your own photos are left off your ballot. Names are hidden. |
| Next Mon | Winner, photographer names and full results are revealed |

The highest average wins. Ties go to the photo with more 7-star ratings, then the photo with more ratings.

All rules are enforced by the database, not the page: @kent.edu only, 4 photos max, one ballot per week, no rating your own photos, ratings sealed until the week closes. Someone editing the page's code in their browser can't get around them.

## Files

- `index.html`: the whole site
- `supabase/setup.sql`: run once in Supabase to create everything

---

## Setup (about 30–45 minutes)

### 1. Create the Supabase project
1. Go to <https://supabase.com>, sign up (free), and click **New project**.
2. Name it `ucm-photo-of-the-week`, set a database password (save it somewhere), and pick region **East US (North Virginia)**.
3. Wait about 2 minutes for it to finish provisioning.

### 2. Create the database
1. In the left sidebar open **SQL Editor** and click **New query**.
2. Paste the entire contents of `supabase/setup.sql` and click **Run**. You should see "Success. No rows returned."

This creates the tables, the @kent.edu-only rule, the voting logic and the `photos` storage bucket. Running it again later is safe; it keeps existing data.

### 3. Switch sign-in emails to a 6-digit code
Kent's email security scans links in incoming mail and can "click" a magic link before you do, which uses it up. A typed code avoids that.

1. Go to **Authentication → Emails** (called **Email Templates** in some dashboard versions).
2. Open the **Magic Link** template and replace the body with:
   ```html
   <h2>Your Photo of the Week sign-in code</h2>
   <p>Enter this code on the sign-in page:</p>
   <p style="font-size:28px;font-weight:bold;letter-spacing:4px">{{ .Token }}</p>
   <p>It expires in an hour. If you didn't ask for it, ignore this email.</p>
   ```
   Set the subject to `Your Photo of the Week code`.
3. Do the same for the **Confirm signup** template. First-time users get that one.

### 4. Set up email sending (do this before inviting the team)
Supabase's built-in email sender is only for testing. It sends just a handful of emails per hour, so a team signing in on the same day will hit the limit and see "Too many codes requested."

Pick one option:

- **Gmail (easiest).** Use a Gmail account you control, ideally a dedicated one like `ucmphotooftheweek@gmail.com`.
  1. Turn on 2-Step Verification for that account.
  2. Create an App Password at <https://myaccount.google.com/apppasswords>.
  3. In Supabase go to **Authentication → Emails → SMTP Settings**, enable custom SMTP, and enter:
     - Host: `smtp.gmail.com`
     - Port: `465`
     - Username: the full Gmail address
     - Password: the 16-character app password
     - Sender email: the Gmail address
     - Sender name: `UCM Photo of the Week`
- **Resend (free tier, better deliverability).** This requires a domain you own and can add DNS records to. Follow Resend's Supabase SMTP guide.

Then open **Authentication → Rate Limits** and raise "emails per hour" to something like 30.

People stay signed in on each device, so after the first week emails are rare.

### 5. Connect the page to Supabase
1. In Supabase open **Project Settings → API** (or **API Keys**).
2. Copy the **Project URL** and the **anon public** key. In newer projects this is called the **publishable** key and starts with `sb_publishable_`.
3. In `index.html`, near the top, replace the two placeholders:
   ```js
   SUPABASE_URL: "https://abcdefghijkl.supabase.co",
   SUPABASE_KEY: "eyJhbGciOi…",
   ```
   This key is meant to be public, so it's fine in a public repo. **Never** paste the `service_role` or secret key here.

### 6. Publish on GitHub Pages
1. Create a new repository on GitHub, e.g. `photo-of-the-week`. Public is fine.
2. Upload `index.html`, `README.md` and the `supabase` folder (**Add file → Upload files**), then commit.
3. Go to **Settings → Pages**, set **Source: Deploy from a branch**, **Branch: main / (root)**, and save.
4. After a minute your site is live at `https://<your-github-username>.github.io/photo-of-the-week/`.
5. Back in Supabase, open **Authentication → URL Configuration** and set **Site URL** to that address.

### 7. Make yourself the admin
1. Open the site, sign in with your @kent.edu email, and enter your name.
2. In Supabase **SQL Editor**, run (with your address):
   ```sql
   insert into public.admins (user_id)
   select id from auth.users where email = 'yourflashline@kent.edu';
   ```
3. Reload the site. An **Admin** box appears at the bottom where you can force this week's stage: open voting early, close and reveal, or go back to following the schedule.

Add co-admins the same way.

### 8. Test before sharing
You need a second @kent.edu account, e.g. a teammate, for a real test:
1. Each of you submits a photo.
2. In the Admin box, choose **Force voting open**. Each of you rates the other's photo and submits.
3. Choose **Close and reveal winner** and check that the winner and results appear.
4. Clear the test data in **SQL Editor**:
   ```sql
   delete from public.ballots;
   delete from public.photos;
   delete from public.stage_overrides;
   ```
   Then go to **Storage → photos** and delete the dated folder.

### 9. Share it
Send the team the GitHub Pages link. They sign in with their @kent.edu email, enter the 6-digit code, and add their name once.

---

## Good to know
- **Photo size.** Uploads are resized in the browser to 2560px on the long side (JPEG, quality 90) to stay inside the free 1 GB of storage. For the Instagram post, get the original file from the winning photographer.
- **Photo links are public.** Anyone holding a photo's link can view it. Links are random and never reveal who uploaded the photo.
- **Free-plan pause.** Supabase pauses free projects after about a week with no activity. Weekly use keeps it awake. If it ever pauses, click **Restore** in the dashboard.
- **Missed deadlines.** Thursday and Sunday cutoffs are 11:59 PM Eastern. Use the Admin box to extend a stage.
- **Cleaning up storage.** Each season, you can delete old week folders under **Storage → photos**. Rows in `photos` that point at deleted files will show a blank frame in Past Winners, so delete those rows too if you want the archive to look clean.
