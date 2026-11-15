// HireLock read-only demo — talks to the LIVE contract on Arbitrum Sepolia.
// No wallet, no signing: only eth_call (jobCount / getJob / pendingWithdrawals).
// To point at a fresh deployment, change CONTRACT below.

const CONTRACT = "0x3B6E7aD423ffc3118F031cBD4226deC870eB14Aa"; // live Sepolia contract
const RPC = "https://sepolia-rollup.arbitrum.io/rpc";

const ABI = [
  "function jobCount() view returns (uint256)",
  "function pendingWithdrawals(address) view returns (uint256)",
  "function getJob(uint256) view returns (tuple(address client,address freelancer,uint256 amount,address arbiter,uint256 deadline,uint256 duration,uint256 createdAt,uint256 startedAt,uint256 submittedAt,bool started,bytes32 workHash,uint256 reserved,address disputer,uint8 clientConfirmed,uint8 freelancerConfirmed,uint8 flag3,uint8 flag4,uint8 flag5,uint8 flag6,uint8 status,string title))",
];

const STATUS = ["Created", "Started", "Submitted", "Released", "Cancelled", "Disputed"];

const $ = (id) => document.getElementById(id);
$("addr").textContent = CONTRACT;

const provider = new ethers.JsonRpcProvider(RPC);
const lock = new ethers.Contract(CONTRACT, ABI, provider);

function fmtTs(v) {
  if (!v || v === 0n) return "—";
  return new Date(Number(v) * 1000).toISOString().replace("T", " ").slice(0, 19) + " UTC";
}
function fmtEth(v) {
  return ethers.formatEther(v) + " ETH";
}
function row(k, v) {
  return `<tr><td>${k}</td><td><code>${v}</code></td></tr>`;
}

async function loadJob(id) {
  const box = $("job");
  box.innerHTML = "Loading…";
  try {
    const j = await lock.getJob(id);
    const status = STATUS[Number(j.status)] ?? ("?" + j.status);
    box.innerHTML = `
      <div style="margin-bottom:.5rem"><span class="status">${status}</span>
      <strong>${j.title || "(no title)"}</strong></div>
      <table>
        ${row("client", j.client)}
        ${row("freelancer", j.freelancer)}
        ${row("arbiter", j.arbiter)}
        ${row("amount (escrow)", fmtEth(j.amount))}
        ${row("deadline", fmtTs(j.deadline))}
        ${row("review window", j.duration + " s")}
        ${row("createdAt", fmtTs(j.createdAt))}
        ${row("startedAt", fmtTs(j.startedAt))}
        ${row("submittedAt", fmtTs(j.submittedAt))}
        ${row("started?", j.started)}
        ${row("workHash", j.workHash)}
        ${row("disputer", j.disputer)}
        ${row("clientConfirmed", j.clientConfirmed)}
        ${row("freelancerConfirmed", j.freelancerConfirmed)}
        ${row("status code", j.status)}
      </table>`;
  } catch (e) {
    box.innerHTML = `<span id="err">Job #${id} not found (jobCount is smaller?) — ${e.shortMessage || e.message}</span>`;
  }
}

async function init() {
  try {
    const n = await lock.jobCount();
    $("count").textContent = n.toString();
    $("net").textContent = "Connected to Arbitrum Sepolia · read-only";
    await loadJob(Number($("jobId").value));
  } catch (e) {
    $("err").textContent = "Could not reach the contract: " + (e.shortMessage || e.message);
    $("net").textContent = "";
  }
}

$("load").onclick = () => loadJob(Number($("jobId").value));
$("prev").onclick = () => {
  const el = $("jobId");
  el.value = Math.max(0, Number(el.value) - 1);
  loadJob(Number(el.value));
};
$("next").onclick = () => {
  const el = $("jobId");
  el.value = Number(el.value) + 1;
  loadJob(Number(el.value));
};

init();
