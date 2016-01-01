/**
 * The objective of this query is to gather data related to cross-posts from
 *   Stack Overflow (SO) to Code Review (CR). A cross-post as defined in this context is
 *   a question which has first been asked on SO and then a short time later asked
 *   again on CR (albeit often slightly modified in the way it is titled or phrased).
 * Querying from 2 or more sites requires cross-database queries, and the following
 *   2 databases are used here. All relevant tables are in the [dbo] schema.
 * - Stack Overflow DB: [cr114406-so]
 * - Code Review DB:    [cr114406]
 * 2 temporary tables are used in order to compensate for the physsical limitations
 *   of SEDE which otherwise will often time out before the query is completed.
 * param @minutesFromSoPostToCrPost int not null : The number of minutes allowed between the original
 *   SO question and its cross-post on CR. Default 120 minutes.
 * param @maximumCharacterCountDifferenceAllowed int not null : The maximum number
 *   of characters difference between the body of the question.
 *   NOTE: The higher the number, the more likely that it's not actually a cross-post.
 */
if object_id('tempdb..#LanguageTags') is not null
    drop table #LanguageTags;
if object_id('tempdb..#CrossPosts') is not null
    drop table #CrossPosts;
go
create table #LanguageTags (
    TagName varchar(35) collate SQL_Latin1_General_CP1_CS_AS
    , CrTagId int
    , SoTagId int
    , constraint pk_#LanguageTags primary key (TagName)
);
go
insert into #LanguageTags (TagName)
values
  ('applescript'),
  ('asp.net-mvc-3'),
  ('bash'),
  ('brainfuck'),
  ('c'),
  ('c#'),
  ('c++'),

  /*SNIP...*/

  ('sql'),
  ('swift'),
  ('wolfram-mathematica'),
  ('xslt');
go
update Langs
   set CrTagId = CrTags.Id
     , SoTagId = SoTags.Id
  from #LanguageTags Langs
 inner join [cr114406].dbo.Tags as CrTags
         on CrTags.TagName = Langs.TagName
 inner join [cr114406-so].dbo.Tags as SoTags
         on SoTags.TagName = Langs.TagName;


declare @questionPost int = 1;
declare @minutesFromSoPostToCrPost int = 120;
declare @maximumCharacterCountDifferenceAllowed int = 1000;

select
    [Primary Stack] = case
        when SoUsers.Reputation >= CrUsers.Reputation then
            'Stack Overflow'
        else
            'Code Review'
        end
  , [Primary User] = case
        when SoUsers.Reputation >= CrUsers.Reputation then
            'http://stackoverflow.com/users/' + convert(varchar(10), SoUsers.Id) + '|' + SoUsers.DisplayName
        else
            'http://codereview.stackexchange.com/users/' + convert(varchar(10), CrUsers.Id) + '|' + CrUsers.DisplayName
        end
        , [SO Original] = 'http://stackoverflow.com/questions/' + convert(varchar(10), SoPosts.Id) + '|' + SoPosts.Title
        , [CR Xpost] = 'http://codereview.stackexchange.com/questions/' + convert(varchar(10), CrPosts.Id) + '|' + CrPosts.Title
  /*Calculate the character difference of the body of both questions.*/
  , [CharCountDiff] = abs(len(CrPosts.Body) - len(SoPosts.Body))
  , [SO Score] = SoPosts.Score
  , [CR Score] = CrPosts.Score
  , [SO Status] = case
        when SoPosts.DeletionDate is not null then 'Deleted'
        when SoPosts.ClosedDate is not null then 'Closed'
        else 'OK' end
  , [CR Status] = case
        when CrPosts.DeletionDate is not null then 'Deleted'
        when CrPosts.ClosedDate is not null then 'Closed'
        else 'OK' end
  /*Check in @Duga comments*/
  , [DugaComments?] = case
        when exists (
            select 1 from [cr114406-so].dbo.Comments as SoComments
            where SoPosts.Id = SoComments.PostId
            and SoComments.Text like '%code%review%'
        ) then 'True' end
  , [SO Answers] = SoPosts.AnswerCount
  , [CR Answers] = CrPosts.AnswerCount
  , [SO Accept?] = case
        when SoPosts.AcceptedAnswerId is not null then 'True' end
  , [CR Accept?] = case
        when CrPosts.AcceptedAnswerId is not null then 'True' end
  , [SO Created] = SoPosts.CreationDate
  , [Minutes to Xpost] = datediff(minute, SoPosts.CreationDate, CrPosts.CreationDate)
  , [Tags] = CrPosts.Tags
  , [CrTagId] = CrPT.TagId
  , [SoTagId] = SoPT.TagId

/*Adding results into temp table to avoid timeouts in `select distinct`*/
into #CrossPosts
from
    /*Common users across CR and SO sites:*/
    [cr114406].dbo.Users as CrUsers
    inner join [cr114406-so].dbo.Users as SoUsers
        /*AccountId is network-wide Id for each user, and
          is distinct from the UserId which is for a specific site*/
        on  CrUsers.AccountId = SoUsers.AccountId

    /*Questions by user on both sites:*/
    inner join [cr114406].dbo.Posts as CrPosts
        on  CrUsers.Id = CrPosts.OwnerUserId
        and CrPosts.PostTypeId = @questionPost
    inner join [cr114406-so].dbo.Posts as SoPosts
        on  SoUsers.Id = SoPosts.OwnerUserId
        and SoPosts.PostTypeId = @questionPost

    /*Bring in tags so we can try to eliminate false matches
      due to unrelated posts potentially being posted by the same
      user on 2 different sites within our scoped time period.*/
    inner join [cr114406].dbo.PostTags as CrPT
        on CrPosts.Id = CrPT.PostId
    inner join [cr114406-so].dbo.PostTags as SoPT
        on SoPosts.Id = SoPT.PostId

where
    /*Q was first posted on SO, then later on CR*/
    SoPosts.CreationDate < CrPosts.CreationDate

    /*Q was posted on CR within a certain number of minutes after being posted on SO*/
    and datediff(minute, SoPosts.CreationDate, CrPosts.CreationDate) <= @minutesFromSoPostToCrPost

    /*Apply filter based on character count difference of the body of both questions.*/
    and abs(len(CrPosts.Body) - len(SoPosts.Body)) <= @maximumCharacterCountDifferenceAllowed
;
/*Use this query to view full result set, or modify it
  according to your needs to aggregate from the #CrossPosts table.*/
select distinct
       CP.[Primary Stack]
     , CP.[Primary User]
     , CP.[SO Original]
     , CP.[CR Xpost]
     , CP.[CharCountDiff]
     , CP.[SO Score]
     , CP.[CR Score]
     , CP.[SO Status]
     , CP.[CR Status]
     , CP.[DugaComments?]
     , CP.[SO Answers]
     , CP.[CR Answers]
     , CP.[SO Accept?]
     , CP.[CR Accept?]
     , CP.[SO Created]
     , CP.[Minutes to Xpost]
     , CP.[Tags]
     , CP.[CrTagId]
     , CP.[SoTagId]
  from #CrossPosts CP
    /*Match at least one language tag from CR->SO per post.*/
 inner join #LanguageTags as Langs
         on Langs.SoTagId = CP.SoTagId
        and Langs.CrTagId = CP.CrTagId
 order by [SO Created] desc;
