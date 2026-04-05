"""Main entry point for trip-planner."""

import from byllm.lib { Model }
import os, requests;
import serpapi;
import from dotenv { load_dotenv }

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
}

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
}
sem Meal.cost = "Estimated cost for a meal in USD";
sem Meal.mealType = "The type of the meal as a string: BREAKFAST, LUNCH, or DINNER";
sem Meal.restaurant = "The name of the restaurant.";

"""Call Tavily search API; returns answer line plus page snippets (shared by meals + flights)."""
def tavily_search(query: str, max_results: int) -> str {
    import from typing { Any }

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

def find_meal_with_context(city: str, web_context: str) -> list[Meal] by llm();
sem find_meal_with_context = "Given a city and live web search context about restaurants there, return exactly 5 Meal objects. Each mealType must be exactly one of these three strings (uppercase): BREAKFAST, LUNCH, DINNER — pick whichever fits that restaurant best. cost is estimated meal price in USD (a number). restaurant is the venue name.";

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
    import datetime;

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
    client = serpapi.Client(api_key="a4a3a49124193634da2f6323b3abee781ea62309a073da69b486dcc031d53ab7");
    results = client.search({
        "engine": "google_flights",
        "departure_id": departure,
        "arrival_id": arrival,
        "currency": "USD",
        "type": "1",
        "outbound_date": outbound_date,
        "return_date": return_date,
        "deep_search": "true",
        "sort_by": "2"
    });

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

"""Map SerpAPI google_flights JSON to Flight objects (LLM prompt used wrong field names vs Flight.cost/src/dst)."""
def flights_from_serpapi_results(results: object) -> list[Flight] {
    import from typing { Any }

    data: Any = results;
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
                cost: float = float(pr);
                out = out + [
                    Flight(
                        src=src,
                        dst=dst,
                        airline=airline,
                        flight_num=flight_num,
                        cost=cost
                    )
                ];
                idx += 1;
            }
        }
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
            return flights_from_serpapi_results(api_output);
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

"""Apply normalize_meal_type to each meal (mutate in place for graph persistence)."""
def normalize_meals(meals: list[Meal]) -> list[Meal] {
    for m in meals {
        m.mealType = normalize_meal_type(m.mealType);
    }
    return meals;
}

"""Enrich a trip with meal ideas (server-side graph + LLM). Meal city comes from the same TravelEndpoint as flight arrival resolution."""
def:pub add_meal(trip_id: str) -> list[Meal] {
    for t in [root()-->][?:Trip] {
        if str(jid(t)) == trip_id {
            dest_ep = resolve_place_for_travel(t.destination);
            city = dest_ep.meal_city;
            if not city {
                city = t.destination.strip();
            }
            web_context = search_web(
                f"most popular restaurants in {city} with must try dishes and affordable price range"
            );
            meals = normalize_meals(find_meal_with_context(city, web_context));
            t.meals = t.meals + meals;
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

    def flight_rows(trip: Trip) -> list[JsxElement] {
        out: list[JsxElement] = [];
        idx: int = 0;
        for f in trip.flights {
            label = f"{f.airline} {f.flight_num}: {f.src} → {f.dst} · " + str(f.cost) + " USD";
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
        for m in trip.meals {
            label = f"{m.restaurant} · {m.mealType} · " + str(m.cost) + " USD";
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
                            3 cheapest flights
                        </button>
                        <button
                            type="button"
                            class="btn btn-secondary"
                            onClick={lambda { add_new_meal(trip); }}
                        >
                            Find meals
                        </button>
                    </div>
                </div>
                <section class="trip-subsection" aria-label="Flights">
                    <h3 class="subsection-title">Flights (Tavily)</h3>
                    <p class="trip-hint">Search live fares; we keep the three lowest USD estimates from the results.</p>
                    {
                        <ul class="flight-list">{flight_rows(trip)}</ul>
                        if len(trip.flights) > 0
                        else <p class="trip-empty">No search yet — use the 3 cheapest flights button (needs TAVILY_API_KEY).</p>
                    }
                </section>
                <section class="trip-subsection" aria-label="Meals">
                    <h3 class="subsection-title">Meals</h3>
                    {
                        <ul class="meal-list">{meal_rows(trip)}</ul>
                        if len(trip.meals) > 0
                        else <p class="trip-empty">No meal ideas yet — use Find meals for AI suggestions.</p>
                    }
                </section>
            </article>;
    }

    def trip_grid_cards() -> list[JsxElement] {
        return [trip_card(trip=t) for t in trips];
    }

    return
        <div class="app">
            <header class="site-header">
                <div class="site-header-inner">
                    <p class="eyebrow">AItinerary</p>
                    <h1 class="site-title">Plan trips and discover meals</h1>
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
                                class="input"
                                value={start_date_text}
                                onChange={lambda e: ChangeEvent { start_date_text = e.target.value; }}
                                onKeyDown={lambda e: KeyboardEvent {
                                    if e.key == "Enter" { add_new_trip(); }
                                }}
                                placeholder="YYYY-MM-DD"
                                autoComplete="off"
                            />
                        </label>
                        <label class="field" for="end-input">
                            <span class="field-label">End</span>
                            <input
                                id="end-input"
                                class="input"
                                value={end_date_text}
                                onChange={lambda e: ChangeEvent { end_date_text = e.target.value; }}
                                onKeyDown={lambda e: KeyboardEvent {
                                    if e.key == "Enter" { add_new_trip(); }
                                }}
                                placeholder="YYYY-MM-DD"
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
