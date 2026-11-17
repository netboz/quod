using System.Text.Json;
using System.Text.Json.Nodes;
using Quod.Client;

// Qualification fixture preparation only: call the existing, accepted Accounts
// owner. Never dispatch an operation again or replace an uncertain result.
var directory=args[2];Directory.CreateDirectory(directory);
using var store=new LocalStore(Path.Combine(directory,"preparation-profile"));
using var key=Identity.Create();store.Create(key.Payload(),true);
using var transport=new Transport(args[0],args[1]);
using var session=new SignedSession(key,store,transport);
using var timeout=new CancellationTokenSource(TimeSpan.FromMinutes(5));
await session.Authenticate(timeout.Token);
var accounts=new Accounts(session,store);await accounts.Discover(timeout.Token);
if(!accounts.CanRegister)throw new Exception("Fresh preparation account unavailable; no replacement or resubmission");
await accounts.Register(timeout.Token);
if(accounts.Human==null)await accounts.Resolve(timeout.Token);
if(accounts.Human==null || accounts.Uncertain)throw new Exception("Original signup unresolved; preparation stops without resubmission");
await accounts.Prepare(timeout.Token);await accounts.FinishSetup(timeout.Token);
if(accounts.Setup==null)await accounts.Resolve(timeout.Token);
if(accounts.Setup==null || accounts.Uncertain || store.Snapshot!.Pending.Count!=0)
    throw new Exception("Original setup unresolved; preparation stops without resubmission");
var corpus=JsonNode.Parse(await File.ReadAllTextAsync(args[3]))!;
await File.WriteAllTextAsync(Path.Combine(directory,"account-backup.json"),
    Backup.Export(key,Json.S(corpus,"passphrase"),store.PortablePayload()));
await File.WriteAllTextAsync(Path.Combine(directory,"original.json"),JsonSerializer.Serialize(new {
    public_key=key.PublicText,human=accounts.Human,setup=accounts.Setup.ToString()}));
Console.WriteLine("OBSERVATION1_FIXTURE_READY settled_signup=true settled_setup=true pending=0");
