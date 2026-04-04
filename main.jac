"""Main entry point for trip-planner."""

import from byllm.lib { Model }
import os;
import from dotenv { load_dotenv }
import from tavily { TavilyClient }
# Client-side imports (useState is auto-injected when using `has` variables)
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

"""Search the live web for restaurant options in a city and return concise results."""
def search_web(query: str) -> str {
    load_dotenv();
    api_key = os.getenv("TAVILY_API_KEY");
    if not api_key {
        return "Web search unavailable: set TAVILY_API_KEY in the server environment.";
    }

    tavily = TavilyClient(api_key=api_key);
    body = tavily.search(
        query=query,
        topic="general",
        search_depth="advanced",
        max_results=5,
        include_answer=True
    );

    answer = body.get("answer", "");
    results = body.get("results", []);
    snippets = [
        f"{item.get('title', 'Untitled')}: {item.get('content', '')}"
        for item in results
    ];
    return "\n".join(([answer] if answer else []) + snippets);
}
sem search_web = "Use Tavily live web search to gather current public web information.";

def find_meal_with_context(city: str, web_context: str) -> list[Meal] by llm();
sem find_meal_with_context = "Given a city and live web search context about restaurants there, return exactly 5 real restaurant meal options as a list of Meal objects with restaurant, best meal type, and estimated meal cost in USD.";

walker:pub add_meal {
    can add with Trip entry {
        city = here.destination;
        web_context = search_web(f"most popular restaurants in {city} with must try dishes and  affordable price range");
        print(f"web context{web_context}");
        meals = find_meal_with_context(city, web_context);
        print(f"meals{meals}");
        here.meals = here.meals + meals;
        report meals;
    }
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

"""Add a flight to a trip"""
def:pub add_flight(trip: Trip, flight: Flight) -> Flight {
    trip.flights.append(flight);
    return flight;
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

    async def add_new_meal(trip: Trip) {
        result = await jid(trip) spawn add_meal();
        if result.reports and result.reports.length > 0 {
            trip.meals = trip.meals + result.reports[0];
            trips = trips + [];
        }
    }


    return 
        <div class="container">
            <h1>Trip Planner</h1>
            <div class="input-row">
                <input
                    class="input"
                    value={origin_text}
                    onChange={lambda e: ChangeEvent { origin_text = e.target.value; }}
                    onKeyPress={lambda e: KeyboardEvent {
                        if e.key == "Enter" { add_new_trip(); }
                    }}
                    placeholder="Origin city"
                />
                <input
                    class="input"
                    value={destination_text}
                    onChange={lambda e: ChangeEvent { destination_text = e.target.value; }}
                    onKeyPress={lambda e: KeyboardEvent {
                        if e.key == "Enter" { add_new_trip(); }
                    }}
                    placeholder="Destination city"
                />
                <input
                    class="input"
                    type="date"
                    value={start_date_text}
                    onChange={lambda e: ChangeEvent { start_date_text = e.target.value; }}
                    onKeyPress={lambda e: KeyboardEvent {
                        if e.key == "Enter" { add_new_trip(); }
                    }}
                />
                <input
                    class="input"
                    type="date"
                    value={end_date_text}
                    onChange={lambda e: ChangeEvent { end_date_text = e.target.value; }}
                    onKeyPress={lambda e: KeyboardEvent {
                        if e.key == "Enter" { add_new_trip(); }
                    }}
                />
                <button class="btn-add" onClick={add_new_trip}>Add</button>
            </div>
            {[
                <div key={jid(t)} class="task-item">
                    <span class="task-title">{f"{t.origin} -> {t.destination} ({t.start_date} to {t.end_date})"}</span>
                    <button class="btn-add" onClick={lambda { add_new_meal(t); }}>Meal</button>
                    {
                        <div>
                            {[
                                <div key={f"{jid(t)}-{meal.restaurant}"} class="task-title">
                                    {f"{meal.restaurant} ({meal.mealType}) - ${meal.cost}"}
                                </div> for meal in t.meals
                            ]}
                        </div> if len(t.meals) > 0 else <></>
                    }
                </div> for t in trips
            ]}
        </div>;
}
