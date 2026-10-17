"use strict";

const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const sandbox = {
  console,
  Math,
  JSON,
  Object,
  Array,
  String,
  Number,
  Error,
  parseInt,
  parseFloat,
};
sandbox.globalThis = sandbox;
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(path.join(__dirname, "bracket.js"), "utf8"), sandbox);
const B = sandbox.TurnierBracket;

function rngFrom(seed) {
  let state = seed >>> 0;
  return function () {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = Math.imul(state ^ (state >>> 15), 1 | state);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function people(count) {
  const classes = ["Krieger", "Magier", "Schurke", "Priester"];
  const rows = [];
  for (let i = 0; i < count; i += 1) {
    rows.push({
      id: "s" + (i + 1),
      character_name: "Held" + (i + 1),
      className: classes[i % classes.length],
      faction: i % 2 === 0 ? "horde" : "alliance",
    });
  }
  return rows;
}

function koMatches(board, round) {
  return board.matches.filter(function (match) {
    return match.stage === "ko" && match.round === round;
  });
}

function pairKey(a, b) {
  return a < b ? a + "|" + b : b + "|" + a;
}

function assertRoundRobin(ids) {
  const pairs = B.roundRobin(ids);
  const seen = {};
  pairs.forEach(function (pair) {
    assert.notStrictEqual(pair[0], pair[1]);
    const key = pairKey(pair[0], pair[1]);
    assert.strictEqual(seen[key], undefined);
    seen[key] = true;
  });
  const expected = (ids.length * (ids.length - 1)) / 2;
  assert.strictEqual(pairs.length, expected);
}

function sameGroupClashes(board) {
  return koMatches(board, 1).filter(function (match) {
    return match.sourceA && match.sourceB && match.sourceA.groupId === match.sourceB.groupId;
  });
}

function roundDuels(round) {
  return round.filter(function (match) { return !match.bye && !match.byeSide; });
}

function roundByes(round) {
  return round.filter(function (match) { return match.bye || match.byeSide; });
}

function placeholderText(round) {
  return round.map(function (match) {
    return (match.placeholderA || "") + " " + (match.placeholderB || "");
  }).join(" ");
}

const five = B.createDraw(people(5), rngFrom(5));
assert.strictEqual(five.mode, "ko");
assert.strictEqual(five.entries.length, 5);
const fiveR1 = koMatches(five, 1);
assert.strictEqual(roundDuels(fiveR1).length, 2);
assert.strictEqual(roundByes(fiveR1).filter(function (match) { return match.bye; }).length, 1);
assert.strictEqual(roundByes(fiveR1)[0].winner, roundByes(fiveR1)[0].a);
assert.ok(!roundByes(fiveR1)[0].b);
const fiveR2 = koMatches(five, 2);
assert.strictEqual(roundDuels(fiveR2).length, 1);
assert.strictEqual(roundByes(fiveR2).length, 1);
assert.ok(placeholderText(fiveR2).indexOf("Sieger Duell 1") !== -1);
assert.ok(placeholderText(fiveR2).indexOf("Freilos wird ausgelost") !== -1);
fiveR2.forEach(function (match) {
  assert.strictEqual(match.a, null);
  assert.strictEqual(match.winner, null);
});
assert.strictEqual(koMatches(five, 3).length, 1);
assert.ok(placeholderText(koMatches(five, 3)).indexOf("Sieger Duell 1") !== -1);
assert.ok(placeholderText(koMatches(five, 3)).indexOf("Freilos wird ausgelost") !== -1);

const six = B.createDraw(people(6), rngFrom(6));
const sixR1 = koMatches(six, 1);
assert.strictEqual(roundDuels(sixR1).length, 3);
assert.strictEqual(roundByes(sixR1).length, 0);
const sixR2 = koMatches(six, 2);
assert.strictEqual(roundDuels(sixR2).length, 1);
assert.strictEqual(roundByes(sixR2).length, 1);
assert.ok(placeholderText(sixR2).indexOf("Sieger Duell 1") !== -1);
assert.ok(placeholderText(sixR2).indexOf("Freilos wird ausgelost") !== -1);
assert.strictEqual(koMatches(six, 3).length, 1);
assert.strictEqual(B.columnTitle(sixR1), "Runde der 6");
assert.strictEqual(B.columnTitle(sixR2), "Runde der 3");
assert.strictEqual(B.columnTitle(koMatches(six, 3)), "Finale");

const sixteen = B.createDraw(people(16), rngFrom(16));
assert.strictEqual(sixteen.mode, "ko");
assert.strictEqual(sixteen.groups.length, 0);
const sixteenR1 = koMatches(sixteen, 1);
assert.strictEqual(sixteenR1.length, 8);
sixteenR1.forEach(function (match) {
  assert.strictEqual(match.bye, false);
  assert.ok(match.a && match.b);
  assert.strictEqual(match.winner, null);
});
assert.strictEqual(koMatches(sixteen, 2).length, 4);
koMatches(sixteen, 2).forEach(function (match) {
  assert.strictEqual(match.a, null);
  assert.strictEqual(match.b, null);
  assert.ok((match.placeholderA || "").indexOf("Sieger Duell") === 0);
});
assert.strictEqual(sixteen.matches.length, 15);

let played = sixteen;
const first = koMatches(played, 1)[0];
played = B.setWinner(played, first.id, first.a, rngFrom(21));
koMatches(played, 2).forEach(function (match) {
  assert.strictEqual(match.a, null);
  assert.strictEqual(match.b, null);
});
koMatches(played, 1).forEach(function (match) {
  if (!match.winner) played = B.setWinner(played, match.id, match.a, rngFrom(22));
});
const sixteenR2 = koMatches(played, 2);
assert.strictEqual(sixteenR2.length, 4);
const seenR2 = {};
sixteenR2.forEach(function (match) {
  assert.ok(match.a && match.b);
  assert.strictEqual(match.bye, false);
  assert.strictEqual(match.winner, null);
  assert.notStrictEqual(match.a, match.b);
  assert.strictEqual(seenR2[match.a], undefined);
  assert.strictEqual(seenR2[match.b], undefined);
  seenR2[match.a] = true;
  seenR2[match.b] = true;
});
const kept = sixteenR2[1];
const keptPair = [kept.a, kept.b];
played = B.setWinner(played, sixteenR2[0].id, sixteenR2[0].a, rngFrom(23));
const keptAfter = koMatches(played, 2)[1];
assert.strictEqual(keptAfter.a, keptPair[0]);
assert.strictEqual(keptAfter.b, keptPair[1]);
played = B.clearWinner(played, first.id);
koMatches(played, 2).forEach(function (match) {
  assert.strictEqual(match.a, null);
  assert.strictEqual(match.winner, null);
  assert.ok((match.placeholderA || "").indexOf("Sieger Duell") === 0);
});

function priorByes(board, roundNo) {
  const had = {};
  board.matches.forEach(function (match) {
    if (match.stage === "ko" && match.round < roundNo && match.bye && match.winner) had[match.winner] = true;
  });
  return had;
}

function assertFilledRound(board, round) {
  const players = [];
  round.forEach(function (match) {
    if (match.a) players.push(match.a);
    if (match.b) players.push(match.b);
  });
  const unique = {};
  players.forEach(function (id) {
    assert.strictEqual(unique[id], undefined);
    unique[id] = true;
  });
  const odd = players.length % 2 === 1;
  const byes = round.filter(function (match) { return match.bye; });
  if (!odd) {
    assert.strictEqual(byes.length, 0);
    round.forEach(function (match) {
      assert.ok(match.a && match.b);
    });
  } else {
    assert.strictEqual(byes.length, 1);
    assert.ok(byes[0].a && !byes[0].b);
    assert.strictEqual(byes[0].winner, byes[0].a);
    const had = priorByes(board, round[0].round);
    const fresh = players.filter(function (id) { return !had[id]; });
    if (fresh.length) assert.ok(fresh.indexOf(byes[0].winner) !== -1);
  }
  return players;
}

for (let count = 2; count <= 16; count += 1) {
  for (let seed = 1; seed <= 4; seed += 1) {
    let board = B.createDraw(people(count), rngFrom(count * 100 + seed));
    const ids = {};
    assertFilledRound(board, koMatches(board, 1)).forEach(function (id) { ids[id] = true; });
    assert.strictEqual(Object.keys(ids).length, count);
    const rng = rngFrom(9000 + count * 10 + seed);
    let guard = 0;
    while (guard < 80) {
      guard += 1;
      const rounds = B.koRounds(board);
      let open = null;
      let started = false;
      for (let r = 0; r < rounds.length; r += 1) {
        const round = rounds[r];
        const hasPlayers = round.some(function (match) { return match.a || match.b; });
        if (!hasPlayers) {
          if (started) {
            assert.ok(placeholderText(round).indexOf("Sieger Duell") !== -1 || round.length === 0);
          }
          break;
        }
        started = true;
        const players = assertFilledRound(board, round);
        if (r > 0) {
          const previous = roundWinnersOf(rounds[r - 1]);
          assert.strictEqual(players.slice().sort().join(","), previous.slice().sort().join(","));
        }
        open = roundDuels(round).find(function (match) { return match.a && match.b && !match.winner; }) || null;
        if (open) break;
      }
      if (!open) break;
      board = B.setWinner(board, open.id, guard % 2 === 0 ? open.a : open.b, rng);
    }
    const rounds = B.koRounds(board);
    const last = rounds[rounds.length - 1];
    const finalMatch = roundDuels(last)[0];
    assert.ok(finalMatch && finalMatch.winner);
    const losses = {};
    board.matches.forEach(function (match) {
      if (match.stage !== "ko" || !match.winner || !match.a || !match.b) return;
      losses[match.winner === match.a ? match.b : match.a] = true;
    });
    const alive = board.entries.filter(function (entry) { return !losses[entry.id]; });
    assert.strictEqual(alive.length, 1);
    assert.strictEqual(alive[0].id, finalMatch.winner);
  }
}

function roundWinnersOf(round) {
  return round.map(function (match) { return match.winner; });
}

const limit = B.createDraw(people(B.KO_LIMIT), rngFrom(1));
assert.strictEqual(B.KO_LIMIT, 32);
assert.strictEqual(limit.mode, "ko");
const groups33 = B.createDraw(people(33), rngFrom(33));
assert.strictEqual(groups33.mode, "groups");
assert.strictEqual(JSON.stringify(B.groupSizes(33)), JSON.stringify([5, 4, 4, 4, 4, 4, 4, 4]));
assert.strictEqual(groups33.groups.length, 8);
assert.strictEqual(groups33.groups.filter(function (group) {
  return groups33.entries.filter(function (entry) { return entry.groupId === group.id; }).length === 5;
}).length, 1);

const forty = B.createDraw(people(40), rngFrom(40));
assert.strictEqual(forty.mode, "groups");
assert.strictEqual(forty.groups.length, 10);
assert.strictEqual(JSON.stringify(B.groupSizes(40)), JSON.stringify([4, 4, 4, 4, 4, 4, 4, 4, 4, 4]));
const groupMatchCount = forty.matches.filter(function (match) { return match.stage === "group"; }).length;
assert.strictEqual(groupMatchCount, 60);
forty.groups.forEach(function (group) {
  const members = forty.entries.filter(function (entry) { return entry.groupId === group.id; });
  assert.strictEqual(members.length, 4);
  assertRoundRobin(members.map(function (entry) { return entry.id; }));
});
assert.strictEqual(koMatches(forty, 1).length, 16);
const fortyByes = koMatches(forty, 1).filter(function (match) { return match.byeSide; });
assert.strictEqual(fortyByes.length, 12);
koMatches(forty, 1).forEach(function (match) {
  assert.strictEqual(match.a, null);
  assert.strictEqual(match.b, null);
  assert.strictEqual(match.winner, null);
});
assert.strictEqual(sameGroupClashes(forty).length, 0);
assert.strictEqual(sameGroupClashes(groups33).length, 0);

assertRoundRobin(["a", "b", "c", "d", "e"]);

const group = forty.groups[0];
let staged = forty;
const members = staged.entries.filter(function (entry) { return entry.groupId === group.id; });
const gMatches = staged.matches.filter(function (match) {
  return match.stage === "group" && match.groupId === group.id;
});
assert.strictEqual(gMatches.length, 6);
function winnerBetween(left, right) {
  return gMatches.find(function (match) {
    return (match.a === left && match.b === right) || (match.a === right && match.b === left);
  });
}
const order = members.slice().sort(function (a, b) { return a.tiebreak - b.tiebreak; });
// order[0] schlägt alle, order[1] schlägt die beiden letzten, order[2] schlägt den letzten.
[[0, 1], [0, 2], [0, 3], [1, 2], [1, 3], [2, 3]].forEach(function (pair) {
  const match = winnerBetween(order[pair[0]].id, order[pair[1]].id);
  staged = B.setWinner(staged, match.id, order[pair[0]].id);
});
assert.strictEqual(B.groupComplete(staged, group.id), true);
const table = B.rankEntries(
  staged.entries.filter(function (entry) { return entry.groupId === group.id; }),
  staged.matches.filter(function (match) { return match.stage === "group" && match.groupId === group.id; })
);
assert.strictEqual(JSON.stringify(table.map(function (row) { return row.id; })), JSON.stringify(order.map(function (entry) { return entry.id; })));
assert.strictEqual(table[0].wins, 3);
assert.strictEqual(table[0].losses, 0);
assert.strictEqual(table[3].wins, 0);
assert.strictEqual(table[3].losses, 3);
const advanced = koMatches(staged, 1).filter(function (match) {
  const sources = [match.sourceA, match.sourceB].filter(Boolean);
  return sources.some(function (source) { return source.groupId === group.id; });
});
const placed = [];
advanced.forEach(function (match) {
  if (match.sourceA && match.sourceA.groupId === group.id) placed.push({ place: match.sourceA.place, id: match.a });
  if (match.sourceB && match.sourceB.groupId === group.id) placed.push({ place: match.sourceB.place, id: match.b });
});
placed.sort(function (a, b) { return a.place - b.place; });
assert.strictEqual(JSON.stringify(placed.map(function (item) { return item.id; })), JSON.stringify([order[0].id, order[1].id]));

// Gleich viele Siege: der direkte Vergleich steht vor dem Los.
const tiedPeople = people(4).map(function (row, index) {
  row.id = "t" + (index + 1);
  return row;
});
let tied = B.createDraw(tiedPeople, rngFrom(7));
assert.strictEqual(tied.mode, "ko");
const manual = {
  mode: "groups",
  entries: tiedPeople.map(function (row, index) {
    return { id: row.id, signupId: row.id, name: row.character_name, className: row.className, faction: row.faction, groupId: "g", tiebreak: index };
  }),
  groups: [{ id: "g", label: "A", sort: 0 }],
  matches: [],
};
[["t1", "t2"], ["t1", "t3"], ["t1", "t4"], ["t2", "t3"], ["t2", "t4"], ["t3", "t4"]].forEach(function (pair, index) {
  manual.matches.push({
    id: "gm" + index,
    stage: "group",
    groupId: "g",
    round: 1,
    slot: index,
    a: pair[0],
    b: pair[1],
    winner: null,
    bye: false,
    byeSide: null,
    feeds: null,
    feedsSlot: null,
  });
});
// t1 und t2 je zwei Siege, t1 gewinnt den direkten Vergleich. t3 ein Sieg, t4 keiner.
[["t1", "t2", "t1"], ["t1", "t3", "t3"], ["t1", "t4", "t1"], ["t2", "t3", "t2"], ["t2", "t4", "t2"], ["t3", "t4", "t4"]].forEach(function (row) {
  const match = manual.matches.find(function (item) {
    return (item.a === row[0] && item.b === row[1]) || (item.a === row[1] && item.b === row[0]);
  });
  match.winner = row[2];
});
const tiedRank = B.rankEntries(manual.entries, manual.matches);
assert.strictEqual(tiedRank[0].id, "t1");
assert.strictEqual(tiedRank[1].id, "t2");
assert.strictEqual(tiedRank[0].wins, 2);
assert.strictEqual(tiedRank[1].wins, 2);
assert.ok(tiedRank[0].h2h > tiedRank[1].h2h);

// Drei Spieler mit gleich vielen Siegen und gleich vielen Siegen untereinander: das Los entscheidet.
manual.matches.forEach(function (match) { match.winner = null; });
[["t1", "t2", "t1"], ["t2", "t3", "t2"], ["t3", "t1", "t3"], ["t1", "t4", "t1"], ["t2", "t4", "t2"], ["t3", "t4", "t3"]].forEach(function (row) {
  const match = manual.matches.find(function (item) {
    return (item.a === row[0] && item.b === row[1]) || (item.a === row[1] && item.b === row[0]);
  });
  match.winner = row[2];
});
manual.entries.forEach(function (entry) {
  if (entry.id === "t1") entry.tiebreak = 5;
  if (entry.id === "t2") entry.tiebreak = 1;
  if (entry.id === "t3") entry.tiebreak = 9;
  if (entry.id === "t4") entry.tiebreak = 0;
});
const randomRank = B.rankEntries(manual.entries, manual.matches);
assert.strictEqual(JSON.stringify(randomRank.map(function (row) { return row.id; })), JSON.stringify(["t2", "t1", "t3", "t4"]));
assert.strictEqual(randomRank[0].wins, 2);
assert.strictEqual(randomRank[0].h2h, randomRank[1].h2h);

assert.strictEqual(B.roundName(1), "Finale");
assert.strictEqual(B.roundName(2), "Halbfinale");
assert.strictEqual(B.roundName(4), "Viertelfinale");
assert.strictEqual(B.roundName(8), "Achtelfinale");
assert.strictEqual(B.roundName(16), "Runde der 32");

const original = people(5);
const snapshot = JSON.stringify(original);
B.createDraw(original, rngFrom(9));
assert.strictEqual(JSON.stringify(original), snapshot);

console.log("bracket tests ok");
