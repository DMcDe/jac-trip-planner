"""Main entry point for trip-planner."""

import from byllm.lib { Model }
import os, requests;
import from dotenv { load_dotenv }
import from serpapi.serp_api_client { SerpApiClient }
import from typing { Any }
import datetime;


cl import "./styles.css";

glob llm = Model(model_name="huggingface/Qwen/Qwen2.5-Coder-7B-Instruct");

node Trip {
    has origin: str,
        destination: str,
        start_date: str,
        end_date: str,
        flights: list[Flight] = [],
        stays: list[Stay] = [],
        meals: list[Meal] = [],
        total_cost: float = 0;
}

obj Flight {
    has src: str;
    has dst: str;
    has airline: str;
    has flight_num: str;
    has cost: float;
    has price_currency: str = "USD";
    has fare_description: str = "";
}
sem Flight.price_currency = "ISO currency code SerpAPI used for the numeric price (we request USD in the API call).";
sem Flight.fare_description = "Short note e.g. SerpAPI/Google Flights fare scope: Round trip, One way, etc.";

obj Stay {
    has name: str;
    has nights: int;
    has checkin: str;
    has checkout: str;
    has cost: float;
}

obj Meal {
    has restaurant: str;
    has mealType: str;
    has cost: float;
    has day_date: str = "";
}
sem Meal.cost = "Estimated cost for a meal in USD";
sem Meal.mealType = "The type of the meal as a string: BREAKFAST, LUNCH, or DINNER";
sem Meal.restaurant = "The name of the restaurant.";
sem Meal.day_date = "ISO date YYYY-MM-DD for this meal slot in the trip itinerary; empty if not part of a day plan.";

"""Call Tavily search API; returns answer line plus page snippets (shared by meals + flights)."""
def tavily_search(query: str, max_results: int) -> str {
    load_dotenv();
    api_key = os.getenv("TAVILY_API_KEY");
    if not api_key {
        return "Search unavailable: set TAVILY_API_KEY in the server environment.";
    }

    resp: Any = requests.post(
        "https://api.tavily.com/search",
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json"
        },
        json={
            "query": query,
            "topic": "general",
            "search_depth": "advanced",
            "max_results": max_results,
            "include_answer": True
        },
        timeout=25
    );
    resp.raise_for_status();
    body: Any = resp.json();

    answer = body.get("answer", "");
    results: Any = body.get("results", []);
    snippets: list[str] = [];
    for item in results {
        row: Any = item;
        line = f"{row.get('title', 'Untitled')}: {row.get('content', '')}";
        snippets = snippets + [line];
    }
    return "\n".join(([answer] if answer else []) + snippets);
}

"""Search the live web for restaurant options in a city and return concise results."""
def search_web(query: str) -> str {
    return tavily_search(query, 5);
}
sem search_web = "Use Tavily live web search to gather current public web information.";

"""Inclusive calendar dates from trip start to end (YYYY-MM-DD), normalized like flight dates."""
def itinerary_dates_list(start_raw: str, end_raw: str) -> list[str] {
    s = normalize_iso_date_for_serpapi(strip_date_quotes(format_date(start_raw.strip())));
    e = normalize_iso_date_for_serpapi(strip_date_quotes(format_date(end_raw.strip())));
    d0 = datetime.date.fromisoformat(s);
    d1 = datetime.date.fromisoformat(e);
    if d1 < d0 {
        d1 = d0;
    }
    dates: list[str] = [];
    cur = d0;
    while cur <= d1 {
        dates = dates + [cur.isoformat()];
        cur = cur + datetime.timedelta(days=1);
    }
    return dates;
}

def find_meal_itinerary_with_context(
    city: str,
    web_context: str,
    dates_csv: str,
    num_days: int
) -> list[Meal] by llm();
sem find_meal_itinerary_with_context = """
city is the destination dining area. web_context is live web search snippets (may include junk like site navigation).

dates_csv is a comma-separated list of exactly num_days calendar dates in YYYY-MM-DD order — one date per day the traveler is on the trip (inclusive from start through end).

Return exactly (2 * num_days) Meal objects in this strict order: walk the dates in dates_csv from first to last; for EACH date output two meals in a row — first mealType LUNCH, second mealType DINNER. Set day_date on each meal to that same YYYY-MM-DD date string (must match the list exactly).

restaurant must be a REAL place name (café, restaurant, market stall, taqueria, etc.) that appears as a business in web_context OR is a well-known establishment in city. NEVER use page chrome: no "Table of Contents", "Skip to content", "Menu", "Home", "Search", "Sign in", "Cookie", "Privacy", "Subscribe", "Read more", section headings, or generic blog UI text. If a line in web_context is not a venue name, ignore it.

Use different restaurant names across the itinerary when web_context supports enough distinct real venues; do not repeat the same restaurant for multiple meals unless unavoidable.

cost is ONE person's estimated meal total in USD (number only, no symbols). Stay realistic and consistent across the trip: for the same city, casual/local lunch and dinner on the same tier should not jump from ~15 USD to ~300 USD unless web_context explicitly names a luxury or tasting-menu venue. Typical casual dining in many cities is often roughly 8–45 USD per meal; fine dining can be higher only when the context clearly supports it. Do not invent luxury prices for generic mentions.

mealType must be exactly LUNCH or DINNER (uppercase) for every meal in this response.
""";

"""Strip LLM-added quotes so SerpAPI gets bare YYYY-MM-DD (quoted dates cause 400 Bad Request)."""
def strip_date_quotes(d: str) -> str {
    s = str(d).strip();
    n = len(s);
    if n >= 2 and s[0] == "'" and s[n - 1] == "'" {
        return s[1:n - 1].strip();
    }
    if n >= 2 and s[0] == "\"" and s[n - 1] == "\"" {
        return s[1:n - 1].strip();
    }
    return s;
}

"""SerpAPI requires real calendar dates. LLM often emits impossible months (e.g. 2026-15-05 from US 5/15/2026)."""
def normalize_iso_date_for_serpapi(raw: str) -> str {

    s = str(raw).strip();
    parts = s.split("-");
    if len(parts) != 3 {
        return s;
    }
    y = int(parts[0]);
    a = int(parts[1]);
    b = int(parts[2]);
    m = a;
    d = b;
    if m > 12 and d >= 1 and d <= 12 {
        m = b;
        d = a;
    }
    dt = datetime.date(y, m, d);
    return dt.isoformat();
}

"""SerpAPI google_flights expects 3-letter IATA. Tavily/LLM sometimes return ICAO (e.g. CYQG → YQG, KJFK → JFK)."""
def normalize_airport_code_for_serpapi(raw: str) -> str {
    s = str(raw).strip().upper();
    n = len(s);
    if n == 4 {
        c0 = s[0];
        if c0 == "C" or c0 == "K" {
            return s[1:4];
        }
    }
    return s;
}

def find_flights_serpapi(departure: str, arrival: str, outbound_date: str, return_date: str) -> object {
    # google-search-results exposes SerpApiClient + get_dict(), not serpapi.Client (that is the newer pip "serpapi" package).

    client = SerpApiClient(
        {
            "engine": "google_flights",
            "departure_id": departure,
            "arrival_id": arrival,
            "currency": "USD",
            "type": "1",
            "outbound_date": outbound_date,
            "return_date": return_date,
            "deep_search": "true",
            "sort_by": "2",
            "api_key": "a4a3a49124193634da2f6323b3abee781ea62309a073da69b486dcc031d53ab7"
        }
    );
    results = client.get_dict();
    print(results);
    return results;
}

def format_date(date: str) -> str by llm();
sem format_date = "Convert the input to ISO date YYYY-MM-DD only. If the input is US style month/day/year (e.g. 5/15/2026, 05/15/2026), month is 1-12 and day is 1-31 — never put the day in the middle. Example: May 15 2026 → 2026-05-15 not 2026-15-05. No quotes or extra text."

"""Web facts about which airport serves the place; the model chooses one consistent IATA + dining city (no hardcoded geography)."""
def airport_facts_context(place_text: str) -> str {
    q = (
        f"For commercial airline travel to or from this place or metro: {place_text}. "
        f"Give the primary passenger airport travelers use: IATA code, official airport name, and the city or region it serves. "
        f"If multiple airports exist, identify the main hub for typical itineraries."
    );
    return tavily_search(q, 3);
}

obj TravelEndpoint {
    has iata: str;
    has meal_city: str;
}
sem TravelEndpoint.iata = "Exactly three letters: the IATA code from web_context for the airport that best matches place_text.";
sem TravelEndpoint.meal_city = "One city name for restaurant search near that airport (how visitors usually refer to the area).";

def parse_travel_endpoint(place_text: str, web_context: str) -> TravelEndpoint by llm();
sem parse_travel_endpoint = """
place_text is the user's origin or destination phrase. web_context is factual search results about airports for that place.

Return TravelEndpoint:
- iata: single primary passenger airport IATA code. Ground the choice in web_context; do not invent codes.
- meal_city: the city to use when searching for restaurants near that airport.

Use place_text together with web_context to resolve ambiguity: pick the airport that serves the geographic location the user meant (including spelling variants), not a distant or unrelated namesake. If web_context is empty or unusable, infer carefully from place_text only.

iata must be three A-Z letters. meal_city must be a place name, not a code.
""";

"""One Tavily + one structured parse per place; SerpAPI and meals both use this so they stay aligned."""
def resolve_place_for_travel(place_text: str) -> TravelEndpoint {
    ctx = airport_facts_context(place_text.strip());
    ep = parse_travel_endpoint(place_text.strip(), ctx);
    return TravelEndpoint(
        iata=normalize_airport_code_for_serpapi(strip_date_quotes(str(ep.iata).strip())),
        meal_city=strip_date_quotes(str(ep.meal_city).strip())
    );
}

"""Normalize SerpAPI best_flights price (usually int USD); no FX math in this app."""
def serpapi_price_to_float(raw: object) -> float {

    r: Any = raw;
    if r is None {
        return 0.0;
    }
    if isinstance(r, bool) {
        return 0.0;
    }
    if isinstance(r, int) {
        return float(r);
    }
    if isinstance(r, float) {
        return r;
    }
    if isinstance(r, dict) {
        for k in ["total", "value", "amount", "price"] {
            if k in r {
                return serpapi_price_to_float(r.get(k));
            }
        }
        return 0.0;
    }
    s = str(r).strip().replace(",", "");
    if s == "" {
        return 0.0;
    }
    try {
        return float(s);
    } except ValueError {
        return 0.0;
    }
}

"""Map SerpAPI google_flights JSON to Flight objects (LLM prompt used wrong field names vs Flight.cost/src/dst)."""
def flights_from_serpapi_results(results: object) -> list[Flight] {

    data: Any = results;
    sp: Any = data.get("search_parameters");
    curr = "USD";
    if isinstance(sp, dict) {
        c = str(sp.get("currency", "USD")).strip();
        if c {
            curr = c;
        }
    }
    rows: Any = data.get("best_flights");
    if not rows {
        rows = data.get("other_flights", []);
    }
    if not rows {
        rows = [];
    }
    out: list[Flight] = [];
    idx: int = 0;
    for opt in rows {
        if idx < 3 {
            legs: Any = opt.get("flights", []);
            if len(legs) > 0 {
                first_leg: Any = legs[0];
                last_leg: Any = legs[len(legs) - 1];
                dep_a: Any = first_leg.get("departure_airport", {});
                arr_a: Any = last_leg.get("arrival_airport", {});
                src = f"{dep_a.get('name', '')} {dep_a.get('time', '')}".strip();
                dst = f"{arr_a.get('name', '')} {arr_a.get('time', '')}".strip();
                airline = str(first_leg.get("airline", "")).strip();
                if not airline {
                    airline = "Flight";
                }
                fn_parts: list[str] = [];
                for lg in legs {
                    fn = str(lg.get("flight_number", "")).strip();
                    if fn {
                        fn_parts = fn_parts + [fn];
                    }
                }
                flight_num = " · ".join(fn_parts) if len(fn_parts) > 0 else "—";
                pr: Any = opt.get("price", 0);
                cost: float = serpapi_price_to_float(pr);
                fare_scope = str(opt.get("type", "")).strip();
                out = out + [
                    Flight(
                        src=src,
                        dst=dst,
                        airline=airline,
                        flight_num=flight_num,
                        cost=cost,
                        price_currency=curr,
                        fare_description=fare_scope
                    )
                ];
                idx += 1;
            }
        }
    }
    if len(out) == 0 {
        err_msg = str(data.get("error", "")).strip();
        si: Any = data.get("search_information");
        state_note = "";
        if si {
            state_note = str(si.get("flights_results_state", "")).strip();
        }
        detail = err_msg;
        if not detail {
            detail = (
                f"No itineraries returned ({state_note})."
                if state_note
                else "No flight itineraries returned for this search."
            );
        }
        out = out + [
            Flight(
                airline="No flights found",
                flight_num="—",
                src=detail,
                dst="Try different dates, a nearby airport, or open the trip on Google Flights.",
                cost=0.0,
                price_currency="USD",
                fare_description=""
            )
        ];
    }
    return out;
}

def:pub conduct_flight_search(trip_id: str) -> list[Flight] {
    for t in [root()-->][?:Trip] {
        if str(jid(t)) == trip_id {
            departure_airport = resolve_place_for_travel(t.origin).iata;
            arrival_airport = resolve_place_for_travel(t.destination).iata;
            departure_date = normalize_iso_date_for_serpapi(
                strip_date_quotes(format_date(t.start_date.strip()))
            );
            arrival_date = normalize_iso_date_for_serpapi(
                strip_date_quotes(format_date(t.end_date.strip()))
            );
            #print(depart_format);
            #print (departure_airport, arrival_airport, out_date, ret_date);
            print(
                f"SerpAPI airports (resolved): {departure_airport} → {arrival_airport} "
                f"dates {departure_date} / {arrival_date}"
            );
            api_output = find_flights_serpapi(departure_airport, arrival_airport, departure_date, arrival_date);
            print(api_output);
            flights = flights_from_serpapi_results(api_output);
            t.total_cost = t.total_cost - t.flights[0].cost;
            t.flights = flights;
            t.total_cost = t.total_cost + flights[0].cost;
            return flights;
        }
    }
    return [];
}


"""Map LLM or numeric junk to a display label; structured output often uses 1/2/3 or wrong ints."""
def normalize_meal_type(raw: str) -> str {
    s = str(raw).strip().upper();
    if s == "1" or s == "BREAKFAST" {
        return "BREAKFAST";
    }
    if s == "2" or s == "LUNCH" {
        return "LUNCH";
    }
    if s == "3" or s == "DINNER" {
        return "DINNER";
    }
    if "BREAKFAST" in s {
        return "BREAKFAST";
    }
    if "LUNCH" in s {
        return "LUNCH";
    }
    if "DINNER" in s {
        return "DINNER";
    }
    return "DINNER";
}

"""Apply normalize_meal_type and clean day_date (mutate in place for graph persistence)."""
def normalize_meals(meals: list[Meal]) -> list[Meal] {
    for m in meals {
        m.mealType = normalize_meal_type(m.mealType);
        m.day_date = strip_date_quotes(str(m.day_date).strip());
    }
    return meals;
}

"""True if the model picked a navigation heading / junk string instead of a venue."""
def meal_restaurant_name_is_garbage(name: str) -> bool {
    s = str(name).strip().lower();
    if len(s) < 2 {
        return True;
    }
    if s == "menu" or s == "home" or s == "search" {
        return True;
    }
    junk: list[str] = [
        "table of contents",
        "skip to",
        "cookie",
        "privacy policy",
        "terms of use",
        "sign in",
        "log in",
        "subscribe",
        "newsletter",
        "read more",
        "click here",
        "navigation",
        "related posts",
        "related articles",
        "share on",
        "follow us",
        "contact us",
        "about us"
    ];
    for phrase in junk {
        if phrase in s {
            return True;
        }
    }
    return False;
}

"""Force day_date from itinerary order so headings always match trip dates (LLM often omits or mis-assigns)."""
def stitch_meal_day_dates(meals: list[Meal], dates: list[str]) -> list[Meal] {
    if len(dates) < 1 {
        return meals;
    }
    i: int = 0;
    for m in meals {
        slot = int(i / 2);
        if slot < len(dates) {
            m.day_date = dates[slot];
        }
        i += 1;
    }
    return meals;
}

"""When cheapest meals in the list look like street food / markets (< 30 USD) but others are extreme, cap obvious outliers."""
def reconcile_meal_cost_outliers(meals: list[Meal]) -> list[Meal] {
    if len(meals) < 2 {
        return meals;
    }
    lo: float = 1e9;
    for m in meals {
        if m.cost < lo {
            lo = m.cost;
        }
    }
    if lo >= 30.0 {
        return meals;
    }
    ceiling: float = 85.0;
    if lo * 5.0 + 20.0 < ceiling {
        ceiling = lo * 5.0 + 20.0;
    }
    for m in meals {
        if m.cost > 120.0 {
            m.cost = min(m.cost, ceiling);
        }
    }
    return meals;
}

"""Replace junk venue names; tighten costs. city is used for the fallback label."""
def sanitize_meal_itinerary(meals: list[Meal], city: str) -> list[Meal] {
    fb = f"Local spot in {city} (pick a name from search)";
    for m in meals {
        if meal_restaurant_name_is_garbage(m.restaurant) {
            m.restaurant = fb;
        }
    }
    return reconcile_meal_cost_outliers(meals);
}

"""Build a day-by-day meal itinerary (two meals per day, varied venues). Replaces prior meal list for the trip."""
def:pub add_meal(trip_id: str) -> list[Meal] {
    for t in [root()-->][?:Trip] {
        if str(jid(t)) == trip_id {
            dest_ep = resolve_place_for_travel(t.destination);
            city = dest_ep.meal_city;
            if not city {
                city = t.destination.strip();
            }
            dates = itinerary_dates_list(t.start_date, t.end_date);
            max_days = 21;
            if len(dates) > max_days {
                dates = dates[0:max_days];
            }
            num_days = len(dates);
            if num_days < 1 {
                dates = [normalize_iso_date_for_serpapi(strip_date_quotes(format_date(t.start_date.strip())))];
                num_days = 1;
            }
            web_context = search_web(
                f"named restaurants and food markets in {city} specific venue names "
                f"locals eat lunch dinner mid-range prices not travel blog navigation"
            );
            dates_csv = ", ".join(dates);
            meals = find_meal_itinerary_with_context(city, web_context, dates_csv, num_days);
            meals = normalize_meals(meals);
            meals = stitch_meal_day_dates(meals, dates);
            meals = sanitize_meal_itinerary(meals, city);
            t.total_cost = t.total_cost - sum(m.cost for m in t.meals);
            t.meals = meals;
            t.total_cost = t.total_cost + sum(m.cost for m in meals);
            return t.meals;
        }
    }
    return [];
}

"""Add a trip and return it"""
def:pub create_trip(origin: str, destination: str, start_date: str, end_date: str) -> Trip {
    trip = root() ++> Trip(
        origin=origin,
        destination=destination,
        start_date=start_date,
        end_date=end_date
    );
    return trip[0];
}


"""Get all trips."""
def:pub get_trips -> list[Trip] {
    return [root()-->][?:Trip];
}

cl def:pub app -> JsxElement {
    has trips: list[Trip] = [],
        origin_text: str = "",
        destination_text: str = "",
        start_date_text: str = "",
        end_date_text: str = "";

    async can with entry {
        trips = await get_trips();
    }

    async def add_new_trip {
        if origin_text.strip() and destination_text.strip() and start_date_text.strip() and end_date_text.strip() {
            trip = await create_trip(
                origin_text.strip(),
                destination_text.strip(),
                start_date_text.strip(),
                end_date_text.strip()
            );
            trips = trips + [trip];
            origin_text = "";
            destination_text = "";
            start_date_text = "";
            end_date_text = "";
        }
    }

    async def search_cheapest_flights(trip: Trip) {
        trip.flights = await conduct_flight_search(str(jid(trip)));
        trips = [x for x in trips];
    }

    async def add_new_meal(trip: Trip) {
        trip.meals = await add_meal(str(jid(trip)));
        trips = [x for x in trips];
    }

    def date_picker() -> JsxElement {
        
    }

    def flight_rows(trip: Trip) -> list[JsxElement] {
        out: list[JsxElement] = [];
        idx: int = 0;
        for f in trip.flights {
            fare_part = (
                f" · {f.fare_description}"
                if str(f.fare_description).strip() != ""
                else ""
            );
            label = (
                f"{f.airline} {f.flight_num}: {f.src} → {f.dst} · "
                + str(f.cost)
                + " "
                + str(f.price_currency).strip()
                + fare_part
            );
            fk = str(jid(trip)) + "-flight-" + str(idx);
            out = out + [
                <li key={fk} class="flight-item">
                    {label}
                </li>
            ];
            idx += 1;
        }
        return out;
    }

    def meal_rows(trip: Trip) -> list[JsxElement] {
        out: list[JsxElement] = [];
        idx: int = 0;
        prev_day: str = "";
        for m in trip.meals {
            day = str(m.day_date).strip();
            if day != "" and day != prev_day {
                prev_day = day;
                hk = str(jid(trip)) + "-meal-day-" + str(idx);
                out = out + [
                    <li key={hk} class="meal-day-heading" role="presentation">
                        <span class="meal-day-label">{day}</span>
                    </li>
                ];
                idx += 1;
            }
            label = f"{m.restaurant} · {m.mealType} · ~" + str(m.cost) + " USD (estimate)";
            meal_key = str(jid(trip)) + "-meal-" + str(idx);
            out = out + [
                <li key={meal_key} class="meal-item">
                    {label}
                </li>
            ];
            idx += 1;
        }
        return out;
    }

    def trip_card(trip: Trip) -> JsxElement {
        return
            <article class="trip-card" key={jid(trip)}>
                <div class="trip-cost">
                    <p>Total Cost: ${trip.total_cost.toFixed(2)}</p>
                </div>
                <div class="trip-card-head">
                    <div class="trip-title-block">
                        <h2 class="trip-destination">{trip.destination}</h2>
                        <p class="trip-route-dates">
                            {trip.origin} → {trip.destination} · {trip.start_date} – {trip.end_date}
                        </p>
                    </div>
                    <div class="trip-card-actions">
                        <button
                            type="button"
                            class="btn btn-secondary"
                            onClick={lambda { search_cheapest_flights(trip); }}
                        >
                            Cheapest Flights
                        </button>
                        <button
                            type="button"
                            class="btn btn-secondary"
                            onClick={lambda { add_new_meal(trip); }}
                        >
                            Build Meal Itinerary
                        </button>
                    </div>
                </div>
                <section class="trip-subsection" aria-label="Flights">
                    <h3 class="subsection-title">Flights (SerpAPI)</h3>
                    <p class="trip-hint">
                        Fares are the numbers SerpAPI returns — we request currency USD and do not convert from other
                        currencies. Default search is round trip; the price is usually the total for both directions,
                        not per leg. Meal costs elsewhere are rough AI estimates in USD, not live menu prices.
                    </p>
                    {
                        <ul class="flight-list">{flight_rows(trip)}</ul>
                        if len(trip.flights) > 0
                        else <p class="trip-empty">No search yet — use &quot;3 cheapest flights&quot; to query SerpAPI.</p>
                    }
                </section>
                <section class="trip-subsection" aria-label="Meal itinerary">
                    <h3 class="subsection-title">Meal itinerary</h3>
                    <p class="trip-hint">
                        Two meals per trip day (lunch and dinner), with different restaurants when possible.
                        Long trips: first 21 days only.
                    </p>
                    {
                        <ul class="meal-list">{meal_rows(trip)}</ul>
                        if len(trip.meals) > 0
                        else <p class="trip-empty">No itinerary yet — use Find meals to build one from your dates.</p>
                    }
                </section>
            </article>;
    }

    def trip_grid_cards() -> list[JsxElement] {
        current_trips = trips if (trips is not None) else [];
        return [trip_card(trip=t) for t in current_trips];
    }

    return
        <div class="app">
            <header class="site-header">
                <div class="site-header-inner">
                    <p class="eyebrow">AItinerary</p>
                    <h1 class="site-title">Plan Trips and Discover Meals</h1>
                    <p class="site-lede">
                        We will find you the three cheapest round flight estimates per trip.
                    </p>
                </div>
            </header>
            <main class="main">
                <section class="panel panel-add" aria-label="New trip">
                    <h2 class="panel-title">New trip</h2>
                    <div class="trip-form-grid">
                        <label class="field" for="origin-input">
                            <span class="field-label">From</span>
                            <input
                                id="origin-input"
                                class="input"
                                value={origin_text}
                                onChange={lambda e: ChangeEvent { origin_text = e.target.value; }}
                                onKeyDown={lambda e: KeyboardEvent {
                                    if e.key == "Enter" { add_new_trip(); }
                                }}
                                placeholder="Origin city"
                                autoComplete="off"
                            />
                        </label>
                        <label class="field" for="dest-input">
                            <span class="field-label">To</span>
                            <input
                                id="dest-input"
                                class="input"
                                value={destination_text}
                                onChange={lambda e: ChangeEvent { destination_text = e.target.value; }}
                                onKeyDown={lambda e: KeyboardEvent {
                                    if e.key == "Enter" { add_new_trip(); }
                                }}
                                placeholder="Destination city"
                                autoComplete="off"
                            />
                        </label>
                        <label class="field" for="start-input">
                            <span class="field-label">Start</span>
                            <input
                                id="start-input"
                                type="date"
                                class="input"
                                value={start_date_text}
                                onChange={lambda e: ChangeEvent { start_date_text = e.target.value; }}
                                onKeyDown={lambda e: KeyboardEvent {
                                    if e.key == "Enter" { add_new_trip(); }
                                }}
                                autoComplete="off"
                            />
                        </label>
                        <label class="field" for="end-input">
                            <span class="field-label">End</span>
                            <input
                                id="end-input"
                                type="date"
                                class="input"
                                value={end_date_text}
                                onChange={lambda e: ChangeEvent { end_date_text = e.target.value; }}
                                onKeyDown={lambda e: KeyboardEvent {
                                    if e.key == "Enter" { add_new_trip(); }
                                }}
                                autoComplete="off"
                            />
                        </label>
                    </div>
                    <div class="panel-actions">
                        <button type="button" class="btn btn-primary" onClick={add_new_trip}>
                            Add trip
                        </button>
                    </div>
                </section>
                <section class="trips-section" aria-label="Your trips">
                    {
                        <div class="trip-grid">{trip_grid_cards()}</div>
                        if len(trips) > 0
                        else
                            <div class="empty-state">
                                <p class="empty-title">No trips yet</p>
                                <p class="empty-copy">Fill in origin, destination, and dates above to start.</p>
                            </div>
                    }
                </section>
            </main>
        </div>;
}
