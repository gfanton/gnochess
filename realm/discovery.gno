// this file concerns mostly with "discovery"; ie. finding information
// about a user's chess playing and previous games

package chess

import (
	"bytes"
	"sort"
	"std"
	"strconv"
	"strings"

	"gno.land/p/demo/avl"
	"gno.land/r/demo/users"
)

type Category byte

const (
	// blanks are reserved for future use (bullet and classic)
	_ Category = iota
	Blitz
	Rapid
	_
	Correspondence
	CategoryMax
)

var categoryList = [...]Category{Blitz, Rapid, Correspondence}

func (c Category) String() string {
	// TODO: convert to array map, for both string and FromString
	switch c {
	case Blitz:
		return "blitz"
	case Rapid:
		return "rapid"
	case Correspondence:
		return "correspondence"
	}
	panic("invalid category")
}

func CategoryFromString(s string) Category {
	switch s {
	case "blitz":
		return Blitz
	case "rapid":
		return Rapid
	case "correspondence":
		return Correspondence
	}
	panic("invalid category")
}

func (tc *TimeControl) Category() Category {
	// https://lichess.org/faq#time-controls
	if tc == nil {
		return Correspondence
	}

	totalTime := tc.Seconds + tc.Increment*40
	switch {
	case tc.Seconds <= 0 || tc.Increment < 0:
		// should not happen
		return Correspondence
	case totalTime < 60*8:
		return Blitz
	default:
		return Rapid
	}
}

// realm state
var (
	playerStore avl.Tree // std.Address -> *Player
	leaderboard [CategoryMax]leaderboardType
)

func GetPlayer(player string) string {
	addr := parsePlayer(player)
	v, ok := playerStore.Get(addr.String())
	if !ok {
		panic("player not found")
	}
	b, err := v.(*Player).MarshalJSON()
	if err != nil {
		panic(err)
	}
	return string(b)
}

// Player contains game-related player information.
type Player struct {
	Address      std.Address
	CategoryInfo [CategoryMax]CategoryInfo
}

type CategoryInfo struct {
	Wins, Losses, Draws int
	*PlayerRating
}

// Score for determining leaderboards.
func (p Player) Score(cat Category) float64 {
	return p.CategoryInfo[cat].Rating
}

// Leaderboard position, 0 indexed.
// Dynamically calculated to avoid having to shift positions when LB changes.
func (p Player) LeaderboardPosition(cat Category) int {
	pos, ok := leaderboard[cat].find(p.Score(cat), p.Address)
	if !ok {
		return -1
	}
	return pos
}

func (p Player) MarshalJSON() ([]byte, error) {
	u := users.GetUserByAddress(p.Address)

	var buf bytes.Buffer
	buf.WriteByte('{')

	buf.WriteString(`"address":"` + p.Address.String() + `",`)
	if u == nil {
		buf.WriteString(`"username":"",`)
	} else {
		buf.WriteString(`"username":"` + u.Name() + `",`)
	}

	for idx, cat := range categoryList {
		stat := p.CategoryInfo[cat]
		buf.WriteString(`"` + cat.String() + `":{`)
		buf.WriteString(`"wins":` + strconv.Itoa(stat.Wins) + ",")
		buf.WriteString(`"losses":` + strconv.Itoa(stat.Losses) + ",")
		buf.WriteString(`"draws":` + strconv.Itoa(stat.Draws) + ",")
		buf.WriteString(`"rating":`)
		if res, err := stat.PlayerRating.MarshalJSON(); err != nil {
			return nil, err
		} else {
			buf.Write(res)
		}
		buf.WriteByte(',')
		buf.WriteString(`"position":` + strconv.Itoa(p.LeaderboardPosition(cat)))
		buf.WriteByte('}')
		if idx != len(categoryList)-1 {
			buf.WriteByte(',')
		}
	}

	buf.WriteByte('}')
	return buf.Bytes(), nil
}

func saveGameResult(g *Game) {
	w, b := getPlayer(g.White), getPlayer(g.Black)

	cat := g.Time.Category()

	// Get numeric result for glicko2.
	var result float64
	switch g.Winner {
	case WinnerWhite:
		w.CategoryInfo[cat].Wins++
		b.CategoryInfo[cat].Losses++
		result = 1
	case WinnerBlack:
		w.CategoryInfo[cat].Losses++
		b.CategoryInfo[cat].Wins++
		result = 0
	case WinnerDraw:
		w.CategoryInfo[cat].Draws++
		b.CategoryInfo[cat].Draws++
		result = 0.5
	default:
		return // TODO: maybe panic
	}

	// Call glicko 2 rating calculator.
	owr, obr := w.CategoryInfo[cat].Rating, b.CategoryInfo[cat].Rating
	updateRatings(playerRatings[cat], []RatingScore{{
		White: g.White,
		Black: g.Black,
		Score: result,
	}})

	// Save in playerStore.
	playerStore.Set(w.Address.String(), w)
	playerStore.Set(b.Address.String(), b)
	if g.Winner != WinnerDraw {
		leaderboard[cat], _ = leaderboard[cat].push(g.White, owr, w.CategoryInfo[cat].Rating)
		leaderboard[cat], _ = leaderboard[cat].push(g.Black, obr, b.CategoryInfo[cat].Rating)
	}
}

func getPlayer(addr std.Address) *Player {
	praw, ok := playerStore.Get(addr.String())
	if ok {
		return praw.(*Player)
	}
	p := &Player{Address: addr}
	for _, cat := range categoryList {
		pr := NewPlayerRating(addr)
		p.CategoryInfo[cat] = CategoryInfo{
			PlayerRating: pr,
		}
		playerRatings[cat] = append(playerRatings[cat], pr)
	}
	playerStore.Set(addr.String(), p)
	return p
}

type lbEntry struct {
	addr  std.Address
	score float64
}

type leaderboardType []lbEntry

// find performs binary search on leaderboard to find the first
// position where score appears, or anything lesser than it.
// Additionally, if addr is given, it finds the position where the given address appears.
// The second return parameter returns whether the address was found.
//
// The index will be 0 if the score is higher than any other on the leaderboard,
// and len(leaderboards) if it is lower than any other.
func (lb leaderboardType) find(score float64, addr std.Address) (int, bool) {
	i := sort.Search(len(lb), func(i int) bool {
		return lb[i].score <= score
	})
	if addr == "" || i == len(lb) {
		return i, false
	}
	for j := 0; lb[i+j].score == score; j++ {
		if lb[i+j].addr == addr {
			return i + j, true
		}
	}
	return i, false
}

// push adds or modifies the player's position in the leaderboard.
// the new leaderboard, and the new position of the player in the leaderboard is returned (0-indexed)
func (lb leaderboardType) push(player std.Address, oldScore, newScore float64) (leaderboardType, int) {
	// determine where the player is, currently
	oldPos, found := lb.find(oldScore, player)
	if found && (oldScore == newScore) {
		return lb, oldPos
	}

	// determine where to place the player next.
	newPos, _ := lb.find(newScore, "")

	var n leaderboardType
	switch {
	case !found:
		n = append(leaderboardType{}, lb[:newPos]...)
		n = append(n, lbEntry{player, newScore})
		n = append(n, lb[newPos:]...)

	case oldPos == newPos:
		n = lb
		n[newPos] = lbEntry{player, newScore}
	case oldPos > newPos:
		n = append(leaderboardType{}, lb[:newPos]...)
		n = append(n, lbEntry{player, newScore})
		n = append(n, lb[newPos:oldPos]...)
		n = append(n, lb[oldPos+1:]...)
	default: // oldPos < newPos
		n = append(leaderboardType{}, lb[:oldPos]...)
		n = append(n, lb[oldPos+1:newPos]...)
		n = append(n, lbEntry{player, newScore})
		n = append(n, lb[newPos:]...)
	}
	return n, newPos
}

// Leaderboard returns a list of all users, ordered by their position in the leaderboard.
// category is one of blitz, rapid or correspondence.
func Leaderboard(category string) string {
	cat := CategoryFromString(category)
	var buf bytes.Buffer
	buf.WriteByte('[')
	for idx, entry := range leaderboard[cat] {
		p, _ := playerStore.Get(entry.addr.String())
		d, err := p.(Player).MarshalJSON()
		if err != nil {
			panic(err)
		}
		buf.Write(d)
		if idx != len(leaderboard[cat])-1 {
			buf.WriteByte(',')
		}
	}
	buf.WriteByte(']')
	return buf.String()
}

// ListGames provides game listing functionality, with filter-based search functionality.
//
// available filters:
//
//	player:<player> white:<player> black:<player> finished:bool
//	limit:int id<cmp>int sort:asc/desc
//	<cmp>: '<' or '>'
//	<player>: either a bech32 address, "@user" (r/demo/users), or "caller"
func ListGames(filters string) string {
	ft := parseFilters(filters)
	results := make([]*Game, 0, ft.limit)
	cb := func(g *Game) (stop bool) {
		if !ft.valid(g) {
			return false
		}
		results = append(results, g)
		return len(results) >= ft.limit
	}

	// iterate over user2games array if we have one;
	// if we don't, iterate over games.
	if ft.u2gAddr != "" {
		v, ok := user2Games.Get(ft.u2gAddr.String())
		if !ok {
			return "[]"
		}
		games := v.([]*Game)
		if ft.reverse {
			for i := len(games) - 1; i >= 0; i-- {
				if cb(games[i]) {
					break
				}
			}
		} else {
			for _, game := range games {
				if cb(game) {
					break
				}
			}
		}
	} else {
		fn := gameStore.Iterate
		if ft.reverse {
			fn = gameStore.ReverseIterate
		}
		fn(ft.minID, ft.maxID, func(_ string, v interface{}) bool {
			return cb(v.(*Game))
		})
	}

	// fast path: no results
	if len(results) == 0 {
		return "[]"
	}

	// encode json
	var buf bytes.Buffer
	buf.WriteByte('[')
	for idx, g := range results {
		buf.WriteString(g.json())
		if idx != len(results)-1 {
			buf.WriteByte(',')
		}
	}
	buf.WriteByte(']')

	return buf.String()
}

type listGamesFilters struct {
	filters []func(*Game) bool
	u2gAddr std.Address
	maxID   string
	minID   string
	limit   int
	reverse bool
}

func (l *listGamesFilters) valid(game *Game) bool {
	for _, filt := range l.filters {
		if !filt(game) {
			return false
		}
	}
	return true
}

func parseFilters(filters string) (r listGamesFilters) {
	// default to desc order
	r.reverse = true

	parts := strings.Fields(filters)
	for _, part := range parts {
		idx := strings.IndexAny(part, ":<>")
		if idx < 0 {
			panic("invalid filter: " + part)
		}
		filt, pred := part[:idx+1], part[idx+1:]
		switch filt {
		case "player:":
			a := parsePlayer(pred)
			r.filters = append(r.filters, func(g *Game) bool { return g.White == a || g.Black == a })
			if r.u2gAddr == "" {
				r.u2gAddr = a
			}
		case "white:":
			a := parsePlayer(pred)
			r.filters = append(r.filters, func(g *Game) bool { return g.White == a })
			if r.u2gAddr == "" {
				r.u2gAddr = a
			}
		case "black:":
			a := parsePlayer(pred)
			r.filters = append(r.filters, func(g *Game) bool { return g.Black == a })
			if r.u2gAddr == "" {
				r.u2gAddr = a
			}
		case "finished:":
			b := parseBool(pred)
			r.filters = append(r.filters, func(g *Game) bool { return g.State.IsFinished() == b })
		case "id<":
			r.maxID = pred
		case "id>":
			r.minID = pred
		case "limit:":
			n, err := strconv.Atoi(pred)
			if err != nil {
				panic(err)
			}
			r.limit = n
		case "sort:":
			r.reverse = pred == "desc"
		default:
			panic("invalid filter: " + filt)
		}
	}
	return
}

func parseBool(s string) bool {
	switch s {
	case "true", "True", "TRUE", "1":
		return true
	case "false", "False", "FALSE", "0":
		return false
	}
	panic("invalid bool " + s)
}

func parsePlayer(s string) std.Address {
	switch {
	case s == "":
		panic("invalid address/user")
	case s == "caller":
		return std.PrevRealm().Addr()
	case s[0] == '@':
		u := users.GetUserByName(s[1:])
		if u == nil {
			panic("user not found: " + s[1:])
		}
		return u.Address()
	case s[0] == 'g':
		return std.Address(s)
	default:
		panic("invalid address/user: " + s)
	}
}
