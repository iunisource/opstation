// Courier booking — one adapter per courier. Each adapter books a parcel and
// returns the tracking number / link and (if the courier gives one) the label.
// Couriers without `book` aren't connected yet: their API is plugged in here
// once the documentation and keys arrive. Nothing else in the app changes.

export type CourierCreds = {
  provider: string;
  api_key?: string | null;
  api_secret?: string | null;
  account_id?: string | null;
  pickup_id?: string | null;
  test_mode?: boolean;
};

export type Parcel = {
  order_no: string;
  name: string;
  phone: string;
  email: string | null;
  address1: string;
  address2: string;
  city: string;
  province: string;
  zip: string;
  country: string;
  cod: number;        // amount the rider collects (0 = prepaid)
  weight_kg: number;
  pieces: number;
  items: string;      // short description, e.g. "2 x Air Filter, 1 x Oil Filter"
  note: string | null;
};

export type Booking = {
  company: string;
  number: string;
  url: string | null;
  label_url?: string | null;         // courier-hosted label (PDF)
  label_pdf_base64?: string | null;  // or the label itself
  raw?: unknown;                     // courier's full answer, kept for support
};

type Adapter = {
  name: string;                      // shown to users / sent to Shopify as the courier
  needsKey: boolean;
  book?: (c: CourierCreds, p: Parcel) => Promise<Booking>;
};

export const COURIERS: Record<string, Adapter> = {
  // Lets the whole flow be tried end to end without a real courier.
  test: {
    name: "Test courier",
    needsKey: false,
    book: async (_c, _p) => ({
      company: "Test courier",
      number: "TEST" + String(Date.now()).slice(-9),
      url: null,
    }),
  },
  // Connected once their API details arrive (see the notes above).
  dex: { name: "DEX Logistics", needsKey: true },
  postex: { name: "PostEx", needsKey: true },
  leopards: { name: "Leopards", needsKey: true },
  trax: { name: "Trax", needsKey: true },
  mnp: { name: "M&P", needsKey: true },
  blueex: { name: "BlueEx", needsKey: true },
  tcs: { name: "TCS", needsKey: true },
};

export async function bookParcel(c: CourierCreds, p: Parcel): Promise<Booking> {
  const a = COURIERS[c.provider];
  if (!a) throw new Error("Choose a courier in Courier settings first.");
  if (!a.book) {
    throw new Error(`${a.name} isn't connected to Opstation yet. Book this parcel in the ${a.name} portal and type the tracking number below.`);
  }
  if (a.needsKey && !c.api_key) {
    throw new Error(`Add the ${a.name} API key in Courier settings first.`);
  }
  const b = await a.book(c, p);
  if (!b.number) throw new Error(`${a.name} did not return a tracking number — please try again.`);
  return b;
}
